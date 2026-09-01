/// A component-local association between durable IDs and live runtime objects.
final class LiveObjectRegistry<Id extends Object, Value extends Object> {
  final Map<Id, Value> _objects = <Id, Value>{};

  int get length => _objects.length;

  bool contains(Id id) => _objects.containsKey(id);

  void bind(Id id, Value value) {
    if (_objects.containsKey(id)) {
      throw StateError('A live object is already bound for $id.');
    }
    _objects[id] = value;
  }

  Value resolve(Id id) {
    final Value? value = _objects[id];
    if (value == null) {
      throw StateError('No live object is bound for $id.');
    }
    return value;
  }

  Value? unbind(Id id) => _objects.remove(id);

  void clear() => _objects.clear();
}
