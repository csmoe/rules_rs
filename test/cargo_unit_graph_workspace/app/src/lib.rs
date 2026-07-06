pub fn render(value: u64) -> String {
    let mut buffer = itoa::Buffer::new();
    let mut rendered = local_util::decorate(buffer.format(value));

    #[cfg(unix)]
    cfg_if::cfg_if! {
        if #[cfg(unix)] {
            rendered.push_str(":unix");
        }
    }

    #[cfg(feature = "json")]
    {
        let json = serde_json::json!({ "value": rendered });
        return json["value"].as_str().unwrap().to_owned();
    }

    rendered
}

#[cfg(test)]
mod tests {
    use super::render;

    #[test]
    fn uses_patch_path_optional_target_and_features() {
        let rendered = render(42);
        assert!(rendered.contains("patched-42"));
        assert!(rendered.contains("fancy"));

        #[cfg(unix)]
        assert!(rendered.ends_with(":unix"));
    }
}
