class HeatRoutine {
  const HeatRoutine({
    required this.id,
    required this.title,
    required this.locationId,
    required this.locationName,
    required this.time,
    required this.weekdays,
    required this.timezone,
    required this.leadMinutes,
    required this.enabled,
  });
  final int id, locationId, leadMinutes;
  final String title, locationName, time, timezone;
  final List<int> weekdays;
  final bool enabled;
  factory HeatRoutine.fromJson(Map<String, dynamic> data) => HeatRoutine(
    id: data['id'] as int,
    title: data['title'] as String,
    locationId: data['location_id'] as int,
    locationName: data['location_name'] as String,
    time: data['time'] as String,
    timezone: data['timezone'] as String,
    weekdays: (data['weekdays'] as List).cast<int>(),
    leadMinutes: data['remind_before_minutes'] as int,
    enabled: data['enabled'] == true,
  );
  Map<String, String> toForm({bool? enabled}) => {
    'title': title,
    'location_id': '$locationId',
    'time': time,
    'weekdays': weekdays.join(','),
    'timezone': timezone,
    'remind_before_minutes': '$leadMinutes',
    'enabled': '${enabled ?? this.enabled}',
  };
  String get daysLabel {
    if (weekdays.length == 7) return 'Every day';
    if (weekdays.join(',') == '0,1,2,3,4') return 'Weekdays';
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays.map((day) => labels[day]).join(', ');
  }
}

class RoutineNotice {
  const RoutineNotice({
    required this.id,
    required this.title,
    required this.body,
    required this.read,
    required this.aiGenerated,
    required this.createdAt,
    this.scheduledFor,
    this.weather,
  });
  final int id;
  final String title, body;
  final bool read, aiGenerated;
  final DateTime createdAt;
  final DateTime? scheduledFor;
  final Map<String, dynamic>? weather;
  factory RoutineNotice.fromJson(Map<String, dynamic> data) => RoutineNotice(
    id: data['id'] as int,
    title: data['title'] as String,
    body: data['body'] as String,
    read: data['read'] == true,
    aiGenerated: data['ai_generated'] == true,
    createdAt: DateTime.parse(data['created_at'] as String),
    scheduledFor: DateTime.tryParse(data['scheduled_for'] as String? ?? ''),
    weather: data['weather'] as Map<String, dynamic>?,
  );
}
