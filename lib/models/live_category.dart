class LiveCategory {
  const LiveCategory({
    required this.categoryId,
    required this.categoryName,
    this.parentId,
  });

  final String categoryId;
  final String categoryName;
  final String? parentId;

  factory LiveCategory.fromJson(Map<String, dynamic> json) {
    return LiveCategory(
      categoryId: _stringFromAny(json['category_id']),
      categoryName: _stringFromAny(json['category_name']),
      parentId: _nullableStringFromAny(json['parent_id']),
    );
  }
}

String _stringFromAny(Object? value) => value?.toString().trim() ?? '';

String? _nullableStringFromAny(Object? value) {
  final parsed = _stringFromAny(value);
  return parsed.isEmpty ? null : parsed;
}
