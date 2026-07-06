"""Helpers for using Cargo's unstable unit graph as a semantic dependency graph."""

_SUPPORTED_UNIT_GRAPH_MODES = {
    "bench": True,
    "build": True,
    "check": True,
    "doc": True,
    "test": True,
}

def _unit_graph_args(cargo_path, mode, triple):
    if mode not in _SUPPORTED_UNIT_GRAPH_MODES:
        fail("Unsupported cargo unit graph mode %r. Supported modes: %s" % (
            mode,
            ", ".join(sorted(_SUPPORTED_UNIT_GRAPH_MODES.keys())),
        ))

    args = [
        cargo_path,
        mode,
        "--unit-graph",
        "-Z",
        "unstable-options",
        "--locked",
        "--offline",
        "--quiet",
    ]
    if triple:
        args.extend(["--target", triple])
    return args

def _check_unit_graph_version(graph):
    version = graph.get("version")
    if version != 1:
        fail("Unsupported Cargo unit graph version %r, expected 1" % version)

def summarize_unit_graph(graph):
    """Preserves Cargo's serialized unit graph with explicit unit indices.

    Cargo serializes UnitGraph as a sorted units array plus dependency edges that
    point at other units by array index. Keep that representation as the source
    of truth instead of deriving our own unit identity or edge kind.
    """

    _check_unit_graph_version(graph)

    units = graph.get("units", [])
    summarized_units = []
    for index, unit in enumerate(units):
        deps = []
        for dep in unit.get("dependencies", []):
            dep_index = dep["index"]
            if dep_index < 0 or dep_index >= len(units):
                fail("Cargo unit graph dependency index %s is out of bounds for %s unit(s)" % (
                    dep_index,
                    len(units),
                ))

            deps.append({
                "index": dep_index,
                "extern_crate_name": dep.get("extern_crate_name"),
                "noprelude": dep.get("noprelude", False),
                "public": dep.get("public", False),
            })

        summarized_units.append({
            "index": index,
            "pkg_id": unit["pkg_id"],
            "target": unit["target"],
            "profile": unit["profile"],
            "mode": unit["mode"],
            "platform": unit.get("platform"),
            "features": unit.get("features", []),
            "is_std": unit.get("is_std", False),
            "dependencies": deps,
        })

    for root in graph.get("roots", []):
        if root < 0 or root >= len(units):
            fail("Cargo unit graph root index %s is out of bounds for %s unit(s)" % (
                root,
                len(units),
            ))

    return struct(
        roots = graph.get("roots", []),
        units = summarized_units,
    )

def _fq_crate(name, version):
    return name + "-" + version

def _parse_pkg_id(pkg_id):
    marker = pkg_id.rfind("#")
    if marker == -1:
        return None

    suffix = pkg_id[marker + 1:]
    at = suffix.rfind("@")
    if at == -1:
        return struct(name = None, version = suffix)

    return struct(
        name = suffix[:at],
        version = suffix[at + 1:],
    )

def _metadata_package_fqs(cargo_metadata):
    fqs = {}
    for package in cargo_metadata.get("packages", []):
        fqs[package["id"]] = _fq_crate(package["name"], package["version"])
    return fqs

def _metadata_package_names(cargo_metadata):
    names = {}
    for package in cargo_metadata.get("packages", []):
        names[package["id"]] = package["name"]
    return names

def _unit_crate_name(unit, metadata_names):
    name = metadata_names.get(unit["pkg_id"])
    if name:
        return name

    parsed = _parse_pkg_id(unit["pkg_id"])
    if parsed and parsed.name:
        return parsed.name

    return unit["target"].get("name", "")

def _unit_fq_crate(unit, metadata_fqs, known_fqs):
    pkg_id = unit["pkg_id"]
    fq = metadata_fqs.get(pkg_id)
    if fq:
        return fq

    parsed = _parse_pkg_id(pkg_id)
    if not parsed:
        return None

    if parsed.name:
        fq = _fq_crate(parsed.name, parsed.version)
        if fq in known_fqs:
            return fq
        return None

    target_name = unit["target"].get("name", "")
    candidates = [
        _fq_crate(target_name, parsed.version),
        _fq_crate(target_name.replace("_", "-"), parsed.version),
    ]
    matches = [candidate for candidate in candidates if candidate in known_fqs]
    if len(matches) == 1:
        return matches[0]

    return None

def _is_custom_build(unit):
    return "custom-build" in unit["target"].get("kind", [])

def _reset_feature_resolutions(feature_resolutions_by_fq_crate, platform_triples):
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
        feature_resolutions.aliases.clear()
        for triple in platform_triples:
            feature_resolutions.features_enabled[triple].clear()
            feature_resolutions.deps[triple].clear()
            feature_resolutions.build_deps[triple].clear()

def _label_for_fq(dep_label_prefix, fq):
    return "%s%s" % (dep_label_prefix, fq)

def apply_unit_graphs_to_feature_resolutions(
        *,
        cargo_metadata,
        unit_graphs,
        feature_resolutions_by_fq_crate,
        platform_triples,
        dep_label_prefix):
    """Materializes dependency/features state from Cargo unit graph edges.

    This intentionally treats Cargo's serialized unit graph as the source of
    truth. Dependency kind is derived from the source/target units, not from
    manifest metadata:
      - custom-build build unit edges become build_deps
      - run-custom-build edges are Cargo's internal link from target crate to
        build script execution and are not rendered as crate deps
      - all other non-custom-build edges become deps
    """

    known_fqs = {fq: True for fq in feature_resolutions_by_fq_crate.keys()}
    metadata_fqs = _metadata_package_fqs(cargo_metadata)
    metadata_names = _metadata_package_names(cargo_metadata)
    workspace_fqs = {fq: True for fq in metadata_fqs.values()}
    workspace_dep_labels_by_triple = {triple: set() for triple in platform_triples}
    workspace_dep_versions_by_name = {}

    _reset_feature_resolutions(feature_resolutions_by_fq_crate, platform_triples)

    for key, graph in unit_graphs.items():
        mode, triple = key
        if triple not in platform_triples:
            fail("Cargo unit graph for %s/%s is not one of platform_triples" % (mode, triple))

        unit_fqs = {}
        unit_names = {}
        for unit in graph.units:
            if unit.get("is_std", False):
                continue

            fq = _unit_fq_crate(unit, metadata_fqs, known_fqs)
            if not fq:
                fail("Could not map Cargo unit graph package id to a crate: %s" % unit["pkg_id"])

            unit_fqs[unit["index"]] = fq
            unit_names[unit["index"]] = _unit_crate_name(unit, metadata_names)
            feature_resolutions_by_fq_crate[fq].features_enabled[triple].update(unit.get("features", []))

        for unit in graph.units:
            from_fq = unit_fqs.get(unit["index"])
            if not from_fq:
                continue

            if unit["mode"] == "run-custom-build":
                continue

            from_is_custom_build = _is_custom_build(unit)
            from_feature_resolutions = feature_resolutions_by_fq_crate[from_fq]

            for dep in unit.get("dependencies", []):
                dep_unit = graph.units[dep["index"]]
                if _is_custom_build(dep_unit):
                    continue

                to_fq = unit_fqs.get(dep["index"])
                if not to_fq:
                    continue

                label = _label_for_fq(dep_label_prefix, to_fq)
                if from_is_custom_build:
                    from_feature_resolutions.build_deps[triple].add(label)
                else:
                    from_feature_resolutions.deps[triple].add(label)
                    if from_fq in workspace_fqs:
                        workspace_dep_labels_by_triple[triple].add(":" + to_fq)
                        dep_name = unit_names.get(dep["index"])
                        if dep_name:
                            versions = workspace_dep_versions_by_name.get(dep_name)
                            if not versions:
                                versions = set()
                                workspace_dep_versions_by_name[dep_name] = versions
                            versions.add(to_fq)

                extern_crate_name = dep.get("extern_crate_name")
                if extern_crate_name:
                    from_feature_resolutions.aliases[label] = extern_crate_name

    return struct(
        workspace_dep_labels_by_triple = workspace_dep_labels_by_triple,
        workspace_dep_versions_by_name = workspace_dep_versions_by_name,
    )

def collect_unit_graphs(mctx, cargo_path, workspace_dir, platform_triples, modes):
    """Runs Cargo unit graph commands and returns normalized graphs by mode/triple."""

    graphs = {}
    for mode in modes:
        for triple in platform_triples:
            result = mctx.execute(
                _unit_graph_args(cargo_path, mode, triple),
                working_directory = workspace_dir,
            )
            if result.return_code != 0:
                fail("cargo %s --unit-graph failed for %s:\n%s\n%s" % (
                    mode,
                    triple,
                    result.stdout,
                    result.stderr,
                ))

            graphs[(mode, triple)] = summarize_unit_graph(json.decode(result.stdout))

    return graphs
