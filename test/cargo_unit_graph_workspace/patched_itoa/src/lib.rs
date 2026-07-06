use std::fmt::{Display, Write};

pub struct Buffer {
    value: String,
}

impl Buffer {
    pub fn new() -> Self {
        Self {
            value: String::new(),
        }
    }

    pub fn format<T: Display>(&mut self, value: T) -> &str {
        self.value.clear();
        write!(&mut self.value, "patched-{value}").unwrap();
        &self.value
    }
}
