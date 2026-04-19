# Petstore — demo project for guile-sage

A tiny pet store API + CLI used to exercise guile-sage's tool suite in
demos and documentation. Not a real product.

## Layout

- `pet.py` — `Pet` data class
- `store.py` — in-memory `Store` with add/get/list/remove
- `api.py` — minimal HTTP handler (stdlib, no Flask dependency)
- `cli.py` — command-line interface over the store
- `test_pet.py` — unit tests (pytest-style, no fixtures)

## Run

```sh
python3 cli.py add "Fido" dog
python3 cli.py list
```

## Test

```sh
python3 -m pytest test_pet.py
```
