require "json"

class Task
  DEFAULT_STATUS = "open"

  attr_reader :title

  def initialize(title)
    @title = title
  end

  def rename(next_title)
    @title = next_title
  end

  def self.from_json(json)
    new(JSON.parse(json)["title"])
  end
end

module TaskFormatting
  def self.label(task)
    task.title.upcase
  end
end

def build_task(title)
  Task.new(title)
end
