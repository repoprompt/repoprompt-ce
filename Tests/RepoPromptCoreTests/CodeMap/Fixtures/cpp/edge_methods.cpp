#include <string>
#include <utility>

namespace app {

struct Task {
    std::string id;
    std::string title;
};

class TaskService {
public:
    explicit TaskService(std::string name);
    std::string label(const Task& task) const;
    static Task draft(std::string title);

private:
    std::string name_;
};

TaskService::TaskService(std::string name) : name_(std::move(name)) {}

std::string TaskService::label(const Task& task) const {
    return name_ + ":" + task.title;
}

Task TaskService::draft(std::string title) {
    return Task{"draft", std::move(title)};
}

}
