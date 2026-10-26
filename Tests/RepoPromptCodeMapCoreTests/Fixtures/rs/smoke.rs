use std::fmt;

pub struct Task {
    pub id: String,
    pub title: String,
}

pub trait Renderable {
    fn render(&self) -> String;
}

impl Task {
    pub fn new(id: String, title: String) -> Self {
        Self { id, title }
    }

    pub fn rename(&mut self, title: String) {
        self.title = title;
    }
}

impl Renderable for Task {
    fn render(&self) -> String {
        format!("{}:{}", self.id, self.title)
    }
}

pub fn default_task() -> Task {
    Task::new("local".into(), "Write tests".into())
}

impl fmt::Display for Task {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.render())
    }
}
