"""Store — in-memory pet store with CRUD operations."""

from typing import Iterator
from pet import Pet


class Store:
    def __init__(self) -> None:
        self._pets: dict[int, Pet] = {}
        self._next_id = 1

    def add(self, name: str, species: str, age: int | None = None) -> Pet:
        pet = Pet(id=self._next_id, name=name, species=species, age=age)
        self._pets[pet.id] = pet
        self._next_id += 1
        return pet

    def get(self, pet_id: int) -> Pet | None:
        return self._pets.get(pet_id)

    def remove(self, pet_id: int) -> bool:
        return self._pets.pop(pet_id, None) is not None

    def list_all(self) -> Iterator[Pet]:
        yield from self._pets.values()
