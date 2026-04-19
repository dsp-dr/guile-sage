"""CLI for the petstore demo."""

import sys
from store import Store


def main(argv: list[str]) -> int:
    store = Store()
    if len(argv) < 2:
        print("usage: cli.py {add|list} [...]")
        return 1
    cmd = argv[1]
    if cmd == "add" and len(argv) >= 4:
        pet = store.add(argv[2], argv[3])
        print(pet.describe())
        return 0
    if cmd == "list":
        for pet in store.list_all():
            print(pet.describe())
        return 0
    print(f"unknown command: {cmd}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
