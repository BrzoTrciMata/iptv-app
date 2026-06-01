import 'media_catalog_item.dart';

class WatchProgress {
  const WatchProgress({
    required this.section,
    required this.item,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  final String section;
  final MediaCatalogItem item;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  double get progress {
    if (duration.inMilliseconds <= 0) {
      return 0;
    }
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);
  }

  Map<String, dynamic> toJson() {
    return {
      'section': section,
      'item': item.toJson(),
      'position_ms': position.inMilliseconds,
      'duration_ms': duration.inMilliseconds,
      'updated_at_ms': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory WatchProgress.fromJson(Map<String, dynamic> json) {
    return WatchProgress(
      section: json['section']?.toString() ?? '',
      item: MediaCatalogItem.fromStoredJson(
        Map<String, dynamic>.from(json['item'] as Map? ?? const {}),
      ),
      position: Duration(milliseconds: _intFromAny(json['position_ms'])),
      duration: Duration(milliseconds: _intFromAny(json['duration_ms'])),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        _intFromAny(json['updated_at_ms']),
      ),
    );
  }
}

int _intFromAny(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
