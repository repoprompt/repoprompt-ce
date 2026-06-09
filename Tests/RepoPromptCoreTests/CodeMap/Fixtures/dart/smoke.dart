import 'dart:async';

class Task {
  final String id;
  String title;

  Task(this.id, this.title);

  String get label => '$id:$title';

  bool rename(String nextTitle) {
    title = nextTitle;
    return title.isNotEmpty;
  }
}

abstract class TaskRepository {
  Future<List<Task>> fetch();
  Future<void> save(Task task);
}

Future<Task> makeTask(String title) async {
  return Task('local', title);
}
