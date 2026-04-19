"""Pet — core data class for the petstore demo."""

from dataclasses import dataclass
from typing import Optional


@dataclass
class Pet:
    id: int
    name: str
    species: str
    age: Optional[int] = None

    def describe(self) -> str:
        age_part = f", {self.age} yrs" if self.age is not None else ""
        return f"{self.name} ({self.species}{age_part})"
