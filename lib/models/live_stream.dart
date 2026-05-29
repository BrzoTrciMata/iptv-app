class LiveStream {
  const LiveStream({
    required this.streamId,
    required this.name,
    required this.categoryId,
    this.streamIcon,
  });

  final String streamId;
  final String name;
  final String categoryId;
  final String? streamIcon;

  factory LiveStream.fromJson(Map<String, dynamic> json) {
    return LiveStream(
      streamId: _stringFromAny(json['stream_id']),
      name: _stringFromAny(json['name']),
      categoryId: _stringFromAny(json['category_id']),
      streamIcon: _nullableStringFromAny(json['stream_icon']),
    );
  }
}

String _stringFromAny(Object? value) => value?.toString().trim() ?? '';

String? _nullableStringFromAny(Object? value) {
  final parsed = _stringFromAny(value);
  return parsed.isEmpty ? null : parsed;
}
