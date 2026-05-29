import 'dart:convert';

class EpgProgram {
  const EpgProgram({
    required this.title,
    this.description,
    this.start,
    this.end,
  });

  final String title;
  final String? description;
  final DateTime? start;
  final DateTime? end;

  factory EpgProgram.fromJson(Map<String, dynamic> json) {
    return EpgProgram(
      title: _decodeMaybeBase64(json['title'] ?? json['name'])
          .ifEmpty('Trenutni program'),
      description: _decodeMaybeBase64(json['description']).nullIfEmpty(),
      start: _parseDate(json['start'] ?? json['start_timestamp']),
      end: _parseDate(json['end'] ?? json['stop'] ?? json['end_timestamp']),
    );
  }
}

DateTime? _parseDate(Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final timestamp = int.tryParse(raw);
  if (timestamp != null) {
    return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  }
  return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
}

String _decodeMaybeBase64(Object? value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) {
    return '';
  }

  try {
    return utf8.decode(base64.decode(raw)).trim();
  } catch (_) {
    return raw;
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;

  String? nullIfEmpty() => isEmpty ? null : this;
}
