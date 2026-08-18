import argparse
import json
import os

def load_tasks():
    if os.path.exists('todo_db.json'):
        with open('todo_db.json', 'r') as f:
            return json.load(f)
    return []

def save_tasks(tasks):
    with open('todo_db.json', 'w') as f:
        json.dump(tasks, f, indent=2)

def add_task(task):
    tasks = load_tasks()
    tasks.append(task)
    save_tasks(tasks)
    print(f"Added task: {task}")

def list_tasks():
    tasks = load_tasks()
    if not tasks:
        print("No tasks found.")
    else:
        for i, task in enumerate(tasks, 1):
            print(f"{i}. {task}")

def delete_task(index):
    tasks = load_tasks()
    if 1 <= index <= len(tasks):
        deleted_task = tasks.pop(index - 1)
        save_tasks(tasks)
        print(f"Deleted task: {deleted_task}")
    else:
        print("Invalid task index.")

def main():
    parser = argparse.ArgumentParser(description='Todo CLI App')
    parser.add_argument('--add', type=str, help='Add a new task')
    parser.add_argument('--list', action='store_true', help='List all tasks')
    parser.add_argument('--delete', type=int, help='Delete a task by index')
    
    args = parser.parse_args()
    
    if args.add:
        add_task(args.add)
    elif args.list:
        list_tasks()
    elif args.delete is not None:
        delete_task(args.delete)
    else:
        parser.print_help()

if __name__ == '__main__':
    main()
