package example;

import java.util.List;

interface TaskRepository {
    List<Task> all();
    void save(Task task);
}

class Task {
    private final String id;
    private String title;

    Task(String id, String title) {
        this.id = id;
        this.title = title;
    }

    String label() {
        return id + ":" + title;
    }

    void rename(String title) {
        this.title = title;
    }
}

public class TaskService {
    private final TaskRepository repository;

    public TaskService(TaskRepository repository) {
        this.repository = repository;
    }

    public List<Task> load() {
        return repository.all();
    }
}
