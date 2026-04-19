"""Tests for Pet and Store."""

from pet import Pet
from store import Store


def test_pet_describe_with_age():
    p = Pet(id=1, name="Fido", species="dog", age=3)
    assert p.describe() == "Fido (dog, 3 yrs)"


def test_pet_describe_no_age():
    p = Pet(id=2, name="Whiskers", species="cat")
    assert p.describe() == "Whiskers (cat)"


def test_store_add_and_list():
    s = Store()
    s.add("Fido", "dog", 3)
    s.add("Whiskers", "cat")
    pets = list(s.list_all())
    assert len(pets) == 2
    assert pets[0].name == "Fido"


def test_store_remove():
    s = Store()
    p = s.add("Temp", "fish")
    assert s.remove(p.id) is True
    assert s.remove(p.id) is False
