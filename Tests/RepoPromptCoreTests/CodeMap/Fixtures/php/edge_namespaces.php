<?php

namespace App\Tasks;

interface TaskRepository
{
    public function find(string $id): ?Task;
}

class Task
{
    public string $id;
    private string $title;

    public function __construct(string $id, string $title)
    {
        $this->id = $id;
        $this->title = $title;
    }

    public function title(): string
    {
        return $this->title;
    }

    public static function draft(string $title): self
    {
        return new self('draft', $title);
    }
}

function task_label(Task $task): string
{
    return $task->title();
}
