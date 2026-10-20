import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/heatguard_models.dart';

enum _HistoryMetric { temperature, humidity, heatIndex, risk }

class HistoryChartCard extends StatefulWidget {
  const HistoryChartCard({
    super.key,
    required this.history,
    required this.hours,
    required this.thresholds,
    required this.onHoursChanged,
  });

  final HeatHistory history;
  final int hours;
  final List<HeatThreshold> thresholds;
  final ValueChanged<int> onHoursChanged;

  @override
  State<HistoryChartCard> createState() => _HistoryChartCardState();
}

class _HistoryChartCardState extends State<HistoryChartCard> {
  _HistoryMetric _metric = _HistoryMetric.heatIndex;
  int? _selectedIndex;

  @override
  Widget build(BuildContext context) {
    final points = widget.history.points;
    final selectedIndex = _selectedIndex == null || points.isEmpty
        ? (points.isEmpty ? null : points.length - 1)
        : _selectedIndex!.clamp(0, points.length - 1).toInt();
    final selected = selectedIndex == null ? null : points[selectedIndex];
    final value = selected == null ? null : _metricValue(selected);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(17, 17, 17, 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('History', style: TextStyle(
                        color: Color(0xFF15251E),
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      )),
                      SizedBox(height: 3),
                      Text('Stored readings for this location', style: TextStyle(
                        color: Color(0xFF77867E),
                        fontSize: 12,
                      )),
                    ],
                  ),
                ),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    textStyle: const WidgetStatePropertyAll(
                      TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 9),
                    ),
                  ),
                  segments: const [
                    ButtonSegment(value: 24, label: Text('24h')),
                    ButtonSegment(value: 168, label: Text('7d')),
                  ],
                  selected: {widget.hours == 168 ? 168 : 24},
                  onSelectionChanged: (value) =>
                      widget.onHoursChanged(value.first),
                ),
              ],
            ),
            const SizedBox(height: 15),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _metricChip(_HistoryMetric.heatIndex, 'Heat index'),
                  const SizedBox(width: 7),
                  _metricChip(_HistoryMetric.temperature, 'Temperature'),
                  const SizedBox(width: 7),
                  _metricChip(_HistoryMetric.humidity, 'Humidity'),
                  const SizedBox(width: 7),
                  _metricChip(_HistoryMetric.risk, 'Risk'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    selected == null
                        ? 'No readings yet'
                        : '${_metricName(_metric)}  ${_formatValue(value)}  ·  ${selected.label}',
                    style: const TextStyle(
                      color: Color(0xFF46574E),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${points.length} readings',
                  style: const TextStyle(
                    color: Color(0xFF96A199),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (points.isEmpty)
              Container(
                height: 190,
                alignment: Alignment.center,
                child: const Text(
                  'No stored readings for this period yet.',
                  style: TextStyle(color: Color(0xFF77867E), fontSize: 13),
                ),
              )
            else
              SizedBox(
                height: 190,
                width: double.infinity,
                child: LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      if (points.length < 2) return;
                      const left = 42.0;
                      const right = 8.0;
                      final plotWidth = math.max(
                        1.0,
                        constraints.maxWidth - left - right,
                      );
                      final ratio = ((details.localPosition.dx - left) /
                              plotWidth)
                          .clamp(0.0, 1.0);
                      setState(() {
                        _selectedIndex = (ratio * (points.length - 1)).round();
                      });
                    },
                    child: CustomPaint(
                      painter: _HistoryChartPainter(
                        points: points,
                        thresholds: widget.thresholds,
                        metric: _metric,
                        selectedIndex: selectedIndex,
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 9),
            Text(
              _metric == _HistoryMetric.heatIndex
                  ? 'Heat index is calculated from weather estimates. Colored lines mark the configured risk bands.'
                  : _metric == _HistoryMetric.risk
                  ? 'Risk levels follow the configured PAGASA heat-index categories.'
                  : 'History contains stored observations; forecast hours are not included.',
              style: const TextStyle(
                color: Color(0xFF87948C),
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricChip(_HistoryMetric metric, String label) {
    final selected = metric == _metric;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() {
        _metric = metric;
        _selectedIndex = null;
      }),
      labelStyle: TextStyle(
        color: selected ? const Color(0xFF17624A) : const Color(0xFF64736B),
        fontSize: 12,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide(
        color: selected ? const Color(0xFFB8D8C6) : const Color(0xFFE5EBE6),
      ),
      backgroundColor: Colors.white,
      selectedColor: const Color(0xFFEAF4ED),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  double? _metricValue(HeatHistoryPoint point) => switch (_metric) {
    _HistoryMetric.temperature => point.temperatureC,
    _HistoryMetric.humidity => point.humidityPct,
    _HistoryMetric.heatIndex => point.heatIndexC,
    _HistoryMetric.risk => point.riskLevel?.toDouble(),
  };

  String _metricName(_HistoryMetric metric) => switch (metric) {
    _HistoryMetric.temperature => 'Air temperature',
    _HistoryMetric.humidity => 'Humidity',
    _HistoryMetric.heatIndex => 'Heat index',
    _HistoryMetric.risk => 'Recorded risk',
  };

  String _formatValue(double? value) {
    if (value == null) return '—';
    if (_metric == _HistoryMetric.risk) {
      final level = value.round();
      return widget.thresholds
          .where((threshold) => threshold.level == level)
          .map((threshold) => threshold.shortLabel)
          .firstOrNull ?? 'Unknown';
    }
    return '${value.toStringAsFixed(1)}${_metric == _HistoryMetric.humidity ? '%' : '°C'}';
  }
}

class _HistoryChartPainter extends CustomPainter {
  const _HistoryChartPainter({
    required this.points,
    required this.thresholds,
    required this.metric,
    required this.selectedIndex,
  });

  final List<HeatHistoryPoint> points;
  final List<HeatThreshold> thresholds;
  final _HistoryMetric metric;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final values = points.map(_valueFor).toList();
    final valid = values.whereType<double>().toList();
    if (valid.isEmpty) return;

    const left = 42.0;
    const right = 8.0;
    const top = 10.0;
    const bottom = 29.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    var minValue = valid.reduce(math.min);
    var maxValue = valid.reduce(math.max);
    if (metric == _HistoryMetric.humidity) {
      minValue = 0;
      maxValue = 100;
    } else if (metric == _HistoryMetric.risk) {
      minValue = 0;
      maxValue = math.max(1, thresholds.length - 1).toDouble();
    } else {
      final pad = math.max(1.5, (maxValue - minValue) * 0.18);
      minValue -= pad;
      maxValue += pad;
      minValue = math.max(0, (minValue / 5).floorToDouble() * 5);
      maxValue = (maxValue / 5).ceilToDouble() * 5;
      if (maxValue <= minValue) maxValue = minValue + 5;
    }

    double yFor(double value) =>
        plot.bottom - ((value - minValue) / (maxValue - minValue)) * plot.height;
    double xFor(int index) => points.length == 1
        ? plot.left + plot.width / 2
        : plot.left + index * plot.width / (points.length - 1);

    final gridPaint = Paint()
      ..color = const Color(0xFFE9EEEA)
      ..strokeWidth = 1;
    final axisStyle = TextStyle(
      color: const Color(0xFF85928B),
      fontSize: 9,
    );
    for (var i = 0; i <= 4; i++) {
      final ratio = i / 4;
      final y = plot.bottom - ratio * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      final value = minValue + ratio * (maxValue - minValue);
      final label = metric == _HistoryMetric.risk
          ? _riskName(value.round())
          : value.toStringAsFixed(0);
      _drawText(canvas, label, Offset(0, y - 6), axisStyle, maxWidth: left - 5);
    }

    if (metric == _HistoryMetric.heatIndex) {
      for (final threshold in thresholds) {
        final value = threshold.minC;
        if (value == null || value <= minValue || value >= maxValue) continue;
        final line = Paint()
          ..color = _parseColor(threshold.color).withValues(alpha: 0.42)
          ..strokeWidth = 1;
        _drawDashedLine(canvas, Offset(plot.left, yFor(value)),
            Offset(plot.right, yFor(value)), line);
      }
    }

    final path = Path();
    var hasStarted = false;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        hasStarted = false;
        continue;
      }
      final point = Offset(xFor(i), yFor(value));
      if (!hasStarted) {
        path.moveTo(point.dx, point.dy);
        hasStarted = true;
      } else {
        if (metric == _HistoryMetric.risk) {
          path.lineTo(point.dx, yFor(values[i - 1]!));
        }
        path.lineTo(point.dx, point.dy);
      }
    }

    if (metric == _HistoryMetric.heatIndex) {
      for (var i = 1; i < points.length; i++) {
        final before = values[i - 1];
        final after = values[i];
        if (before == null || after == null) continue;
        canvas.drawLine(
          Offset(xFor(i - 1), yFor(before)),
          Offset(xFor(i), yFor(after)),
          Paint()
            ..color = _colorForRisk(points[i].riskKey)
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round,
        );
      }
    } else {
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF21805B)
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    final last = selectedIndex ?? points.length - 1;
    if (last >= 0 && last < values.length && values[last] != null) {
      final marker = Offset(xFor(last), yFor(values[last]!));
      canvas.drawCircle(marker, 6, Paint()..color = const Color(0xFFEAF4ED));
      canvas.drawCircle(marker, 3.6, Paint()..color = const Color(0xFF17624A));
    }

    for (final index in <int>{0, points.length ~/ 2, points.length - 1}) {
      final rawLabel = points[index].label;
      final label = rawLabel.contains(',')
          ? rawLabel.split(',').first
          : rawLabel;
      final width = 70.0;
      final x = (xFor(index) - width / 2)
          .clamp(0.0, size.width - width)
          .toDouble();
      _drawText(
        canvas,
        label,
        Offset(x, plot.bottom + 7),
        axisStyle,
        maxWidth: width,
        align: TextAlign.center,
      );
    }
  }

  double? _valueFor(HeatHistoryPoint point) => switch (metric) {
    _HistoryMetric.temperature => point.temperatureC,
    _HistoryMetric.humidity => point.humidityPct,
    _HistoryMetric.heatIndex => point.heatIndexC,
    _HistoryMetric.risk => point.riskLevel?.toDouble(),
  };

  String _riskName(int level) {
    return thresholds
            .where((threshold) => threshold.level == level)
            .map((threshold) => threshold.shortLabel)
            .firstOrNull ??
        '';
  }

  Color _colorForRisk(String key) {
    return thresholds
            .where((threshold) => threshold.key == key)
            .map((threshold) => _parseColor(threshold.color))
            .firstOrNull ??
        const Color(0xFF21805B);
  }

  Color _parseColor(String value) {
    final cleaned = value.replaceFirst('#', '');
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return const Color(0xFF21805B);
    return Color(cleaned.length == 6 ? 0xFF000000 | parsed : parsed);
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    double maxWidth = 120,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dash = 4.0;
    const gap = 4.0;
    final distance = (end - start).distance;
    final direction = (end - start) / distance;
    var travelled = 0.0;
    while (travelled < distance) {
      final next = math.min(travelled + dash, distance);
      canvas.drawLine(start + direction * travelled, start + direction * next, paint);
      travelled = next + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _HistoryChartPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.thresholds != thresholds ||
      oldDelegate.metric != metric ||
      oldDelegate.selectedIndex != selectedIndex;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
