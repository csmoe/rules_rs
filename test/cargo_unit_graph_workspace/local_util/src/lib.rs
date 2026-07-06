pub fn decorate(value: &str) -> String {
    #[cfg(feature = "fancy")]
    {
        return format!("fancy:{value}");
    }

    #[cfg(not(feature = "fancy"))]
    {
        value.to_owned()
    }
}
