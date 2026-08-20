using System;

interface TaskRepository
{
    void Save(Task task);
}

class Task
{
    private string title;

    public string Label()
    {
        return title;
    }

    public void Rename(string title)
    {
        this.title = title;
    }
}
