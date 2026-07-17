# 0.2.0

- Search now matches inside JSON payloads (`data`) and errors, not just message/layer.
- Matches are highlighted in expanded data/error/stack blocks.
- Records whose payload or error matches the query auto-expand while searching.
- Expand-all / collapse-all toggle in the app bar.
- Pretty-printed JSON is cached per record instead of re-encoded every rebuild.
- Copy JSON button on expanded records with data — copies the payload alone as
  indent-2 JSON that pastes into editors and `jq`; unencodable values fall back
  to `toString`.
- Copy-all and long-press copies now embed `data` as JSON (`{"id": 42}`), not
  Dart-map `toString()` (`{id: 42}`).

# 0.1.0

Initial release: in-app viewer integration for stratalog.
