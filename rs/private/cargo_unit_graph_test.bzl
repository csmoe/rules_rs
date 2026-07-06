load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cargo_unit_graph.bzl", "apply_unit_graphs_to_feature_resolutions", "summarize_unit_graph")

def _feature_resolutions(platform_triples):
    return struct(
        aliases = {},
        build_deps = {triple: set() for triple in platform_triples},
        deps = {triple: set() for triple in platform_triples},
        features_enabled = {triple: set() for triple in platform_triples},
    )

def _summarize_unit_graph_preserves_features_and_extern_names_impl(ctx):
    env = unittest.begin(ctx)

    graph = {
        "version": 1,
        "units": [
            {
                "dependencies": [
                    {
                        "extern_crate_name": "dep_crate",
                        "index": 1,
                        "noprelude": False,
                        "public": False,
                    },
                ],
                "features": ["default"],
                "mode": "build",
                "pkg_id": "path+file:///repo/consumer#0.1.0",
                "platform": "x86_64-unknown-linux-gnu",
                "profile": {
                    "name": "dev",
                },
                "target": {
                    "crate_types": ["lib"],
                    "kind": ["lib"],
                    "name": "consumer",
                },
            },
            {
                "dependencies": [],
                "features": ["serde"],
                "mode": "build",
                "pkg_id": "path+file:///repo/dep-crate#0.1.0",
                "platform": "x86_64-unknown-linux-gnu",
                "profile": {
                    "name": "dev",
                },
                "target": {
                    "crate_types": ["lib"],
                    "kind": ["lib"],
                    "name": "dep_crate",
                },
            },
        ],
        "roots": [0],
    }

    got = summarize_unit_graph(graph)

    asserts.equals(env, [0], got.roots)
    asserts.equals(env, ["default"], got.units[0]["features"])
    asserts.equals(env, "dep_crate", got.units[0]["dependencies"][0]["extern_crate_name"])
    asserts.equals(env, ["serde"], got.units[1]["features"])
    asserts.equals(env, 1, got.units[0]["dependencies"][0]["index"])
    asserts.equals(env, graph["units"][0]["target"], got.units[0]["target"])
    asserts.equals(env, graph["units"][0]["profile"], got.units[0]["profile"])

    return unittest.end(env)

summarize_unit_graph_preserves_features_and_extern_names_test = unittest.make(_summarize_unit_graph_preserves_features_and_extern_names_impl)

def _apply_unit_graphs_materializes_unit_edges_impl(ctx):
    env = unittest.begin(ctx)

    triple = "x86_64-pc-windows-msvc"
    root_pkg_id = "path+file:///repo/root#0.1.0"
    graph = summarize_unit_graph({
        "version": 1,
        "units": [
            {
                "dependencies": [
                    {
                        "extern_crate_name": "dep",
                        "index": 1,
                    },
                    {
                        "extern_crate_name": "build_script_build",
                        "index": 2,
                    },
                    {
                        "extern_crate_name": "pm",
                        "index": 4,
                    },
                ],
                "features": ["full"],
                "mode": "build",
                "pkg_id": root_pkg_id,
                "platform": triple,
                "profile": {"name": "dev"},
                "target": {
                    "crate_types": ["lib"],
                    "kind": ["lib"],
                    "name": "root",
                },
            },
            {
                "dependencies": [],
                "features": ["default"],
                "mode": "build",
                "pkg_id": "registry+https://github.com/rust-lang/crates.io-index#dep@1.0.0",
                "platform": triple,
                "profile": {"name": "dev"},
                "target": {
                    "crate_types": ["lib"],
                    "kind": ["lib"],
                    "name": "dep",
                },
            },
            {
                "dependencies": [
                    {
                        "extern_crate_name": "build_script_build",
                        "index": 3,
                    },
                ],
                "features": ["full"],
                "mode": "run-custom-build",
                "pkg_id": root_pkg_id,
                "platform": triple,
                "profile": {"name": "dev"},
                "target": {
                    "crate_types": ["bin"],
                    "kind": ["custom-build"],
                    "name": "build-script-build",
                },
            },
            {
                "dependencies": [
                    {
                        "extern_crate_name": "build_dep",
                        "index": 5,
                    },
                ],
                "features": ["full"],
                "mode": "build",
                "pkg_id": root_pkg_id,
                "platform": None,
                "profile": {"name": "dev"},
                "target": {
                    "crate_types": ["bin"],
                    "kind": ["custom-build"],
                    "name": "build-script-build",
                },
            },
            {
                "dependencies": [],
                "features": ["derive"],
                "mode": "build",
                "pkg_id": "registry+https://github.com/rust-lang/crates.io-index#pm@1.0.0",
                "platform": None,
                "profile": {"name": "dev"},
                "target": {
                    "crate_types": ["proc-macro"],
                    "kind": ["proc-macro"],
                    "name": "pm",
                },
            },
            {
                "dependencies": [],
                "features": ["default"],
                "mode": "build",
                "pkg_id": "registry+https://github.com/rust-lang/crates.io-index#build-dep@1.0.0",
                "platform": None,
                "profile": {"name": "dev"},
                "target": {
                    "crate_types": ["lib"],
                    "kind": ["lib"],
                    "name": "build_dep",
                },
            },
        ],
        "roots": [0],
    })

    feature_resolutions = {
        "build-dep-1.0.0": _feature_resolutions([triple]),
        "dep-1.0.0": _feature_resolutions([triple]),
        "pm-1.0.0": _feature_resolutions([triple]),
        "root-0.1.0": _feature_resolutions([triple]),
    }

    got = apply_unit_graphs_to_feature_resolutions(
        cargo_metadata = {
            "packages": [
                {
                    "id": root_pkg_id,
                    "name": "root",
                    "version": "0.1.0",
                },
            ],
        },
        dep_label_prefix = "@hub//:",
        feature_resolutions_by_fq_crate = feature_resolutions,
        platform_triples = [triple],
        unit_graphs = {("build", triple): graph},
    )

    asserts.equals(env, ["full"], sorted(feature_resolutions["root-0.1.0"].features_enabled[triple]))
    asserts.equals(env, ["@hub//:build-dep-1.0.0"], sorted(feature_resolutions["root-0.1.0"].build_deps[triple]))
    asserts.equals(env, ["@hub//:dep-1.0.0", "@hub//:pm-1.0.0"], sorted(feature_resolutions["root-0.1.0"].deps[triple]))
    asserts.equals(env, [":dep-1.0.0", ":pm-1.0.0"], sorted(got.workspace_dep_labels_by_triple[triple]))
    asserts.equals(env, ["dep-1.0.0"], sorted(got.workspace_dep_versions_by_name["dep"]))
    asserts.equals(env, ["pm-1.0.0"], sorted(got.workspace_dep_versions_by_name["pm"]))
    asserts.equals(env, ["derive"], sorted(feature_resolutions["pm-1.0.0"].features_enabled[triple]))

    return unittest.end(env)

apply_unit_graphs_materializes_unit_edges_test = unittest.make(_apply_unit_graphs_materializes_unit_edges_impl)

def cargo_unit_graph_tests():
    return unittest.suite(
        "cargo_unit_graph_tests",
        apply_unit_graphs_materializes_unit_edges_test,
        summarize_unit_graph_preserves_features_and_extern_names_test,
    )
