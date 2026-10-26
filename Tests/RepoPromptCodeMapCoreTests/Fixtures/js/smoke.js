import EventEmitter from "events";

export class TaskStore extends EventEmitter {
  constructor() {
    super();
    this.items = [];
  }

  add(task) {
    this.items.push(task);
    this.emit("add", task);
  }

  get count() {
    return this.items.length;
  }
}

export function normalizeTask(input) {
  return { id: input.id, title: input.title.trim(), label: `${input.id}:${input.title.trim()}` };
}

export const createTask = (title) => ({
  id: title.toLowerCase(),
  title,
});
