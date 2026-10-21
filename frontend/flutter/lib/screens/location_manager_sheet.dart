import 'package:flutter/material.dart';

import '../models/heatguard_models.dart';
import '../services/heatguard_api.dart';
import '../theme/heatguard_theme.dart';

class LocationManagerSheet extends StatefulWidget {
  const LocationManagerSheet({
    super.key,
    required this.api,
    required this.baseUrl,
  });

  final HeatGuardApi api;
  final String baseUrl;

  @override
  State<LocationManagerSheet> createState() => _LocationManagerSheetState();
}

class _LocationManagerSheetState extends State<LocationManagerSheet> {
  final TextEditingController _queryController = TextEditingController();
  List<GeocodeResult> _results = const [];
  List<AddressOption> _regions = const [];
  List<AddressOption> _provinces = const [];
  List<AddressOption> _cities = const [];
  List<AddressOption> _barangays = const [];
  String? _regionCode;
  String? _provinceCode;
  String? _cityCode;
  String? _barangayCode;
  String? _error;
  bool _busy = false;
  bool _searchComplete = false;
  bool _loadingRegions = true;

  @override
  void initState() {
    super.initState();
    _loadRegions();
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _loadRegions() async {
    try {
      final values = await widget.api.fetchAddressOptions(
        widget.baseUrl,
        path: '/api/address/regions',
        key: 'regions',
      );
      if (!mounted) return;
      setState(() {
        _regions = values;
        _loadingRegions = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingRegions = false;
        _error = _message(error);
      });
    }
  }

  Future<void> _loadProvinces(String regionCode) async {
    try {
      final values = await widget.api.fetchAddressOptions(
        widget.baseUrl,
        path: '/api/address/provinces',
        key: 'provinces',
        queryParameters: {'region_code': regionCode},
      );
      if (!mounted || regionCode != _regionCode) return;
      setState(() => _provinces = values);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _loadCities(String provinceCode) async {
    try {
      final values = await widget.api.fetchAddressOptions(
        widget.baseUrl,
        path: '/api/address/cities',
        key: 'cities',
        queryParameters: {'province_code': provinceCode},
      );
      if (!mounted || provinceCode != _provinceCode) return;
      setState(() => _cities = values);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _loadBarangays(String cityCode) async {
    try {
      final values = await widget.api.fetchAddressOptions(
        widget.baseUrl,
        path: '/api/address/barangays',
        key: 'barangays',
        queryParameters: {'city_code': cityCode},
      );
      if (!mounted || cityCode != _cityCode) return;
      setState(() => _barangays = values);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.length < 2) {
      setState(() {
        _error = 'Type at least two characters to search.';
        _searchComplete = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _searchComplete = false;
    });
    try {
      final data = await widget.api.searchLocations(widget.baseUrl, query);
      final raw = data['results'];
      if (!mounted) return;
      setState(() {
        _results = raw is List
            ? raw
                  .whereType<Map<String, dynamic>>()
                  .map(GeocodeResult.fromJson)
                  .toList()
            : const [];
        _searchComplete = true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addSearchResult(GeocodeResult result) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await widget.api.createLocation(widget.baseUrl, result);
      final location = response['location'];
      final id = location is Map<String, dynamic>
          ? int.tryParse(location['id'].toString())
          : null;
      if (id == null) {
        throw const FormatException('The location was not created.');
      }
      if (mounted) Navigator.of(context).pop(id);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addAddress() async {
    final region = _regionCode;
    final province = _provinceCode;
    final city = _cityCode;
    final barangay = _barangayCode;
    if (region == null ||
        province == null ||
        city == null ||
        barangay == null) {
      setState(() => _error = 'Choose a region, province, city, and barangay.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await widget.api.createAddressLocation(
        widget.baseUrl,
        regionCode: region,
        provinceCode: province,
        cityCode: city,
        barangayCode: barangay,
      );
      final location = response['location'];
      final id = location is Map<String, dynamic>
          ? int.tryParse(location['id'].toString())
          : null;
      if (id == null) throw const FormatException('The address was not added.');
      if (mounted) Navigator.of(context).pop(id);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object error) => error is HeatGuardApiException
      ? error.message
      : 'HeatGuard could not complete this request.';

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.86,
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: HeatGuardColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 17, 12, 10),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Add a monitoring location',
                              style: TextStyle(
                                color: HeatGuardColors.ink,
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Find your place. We will keep an eye on the heat.',
                              style: TextStyle(
                                color: HeatGuardColors.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const TabBar(
                  labelColor: HeatGuardColors.teal,
                  tabs: [
                    Tab(
                      icon: Icon(Icons.search_rounded),
                      text: 'Search by name',
                    ),
                    Tab(icon: Icon(Icons.map_outlined), text: 'Browse address'),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Material(
                      color: const Color(0xFFFFF2E2),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(11),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.info_outline_rounded,
                              color: Color(0xFF9A5A18),
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Color(0xFF75450F),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: TabBarView(children: [_searchTab(), _addressTab()]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 22),
      children: [
        TextField(
          controller: _queryController,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            labelText: 'Place name',
            hintText: 'For example, Quezon City',
            prefixIcon: const Icon(Icons.place_outlined),
            suffixIcon: IconButton(
              tooltip: 'Search',
              onPressed: _busy ? null : _search,
              icon: const Icon(Icons.search_rounded),
            ),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _busy ? null : _search,
          icon: const Icon(Icons.search_rounded),
          label: const Text('Search places'),
        ),
        if (_busy) ...[
          const SizedBox(height: 18),
          const Center(
            child: CircularProgressIndicator(color: HeatGuardColors.teal),
          ),
        ],
        if (_searchComplete && !_busy && _results.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 22),
            child: Text(
              'No matching places found. Try another spelling.',
              textAlign: TextAlign.center,
              style: TextStyle(color: HeatGuardColors.muted),
            ),
          ),
        for (final result in _results)
          Card(
            margin: const EdgeInsets.only(top: 10),
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: HeatGuardColors.mint,
                child: Icon(
                  Icons.location_on_outlined,
                  color: HeatGuardColors.teal,
                ),
              ),
              title: Text(result.name),
              subtitle: Text(
                [result.admin1, result.country]
                    .whereType<String>()
                    .where((value) => value.isNotEmpty)
                    .join(', '),
              ),
              trailing: IconButton(
                tooltip: 'Add ${result.name}',
                onPressed: _busy ? null : () => _addSearchResult(result),
                icon: const Icon(
                  Icons.add_circle_outline_rounded,
                  color: HeatGuardColors.teal,
                ),
              ),
              onTap: _busy ? null : () => _addSearchResult(result),
            ),
          ),
      ],
    );
  }

  Widget _addressTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 22),
      children: [
        _addressDropdown(
          label: 'Region',
          value: _regionCode,
          options: _regions,
          loading: _loadingRegions,
          placeholder: 'Select a region',
          onChanged: (code) {
            if (code == null) return;
            setState(() {
              _regionCode = code;
              _provinceCode = null;
              _cityCode = null;
              _barangayCode = null;
              _provinces = _cities = _barangays = const [];
              _error = null;
            });
            _loadProvinces(code);
          },
        ),
        const SizedBox(height: 13),
        _addressDropdown(
          label: 'Province or independent city',
          value: _provinceCode,
          options: _provinces,
          placeholder: _regionCode == null
              ? 'Choose a region first'
              : 'Select a province or city',
          onChanged: (code) {
            if (code == null) return;
            setState(() {
              _provinceCode = code;
              _cityCode = null;
              _barangayCode = null;
              _cities = _barangays = const [];
              _error = null;
            });
            _loadCities(code);
          },
        ),
        const SizedBox(height: 13),
        _addressDropdown(
          label: 'City or municipality',
          value: _cityCode,
          options: _cities,
          placeholder: _provinceCode == null
              ? 'Choose a province or city first'
              : 'Select a city or municipality',
          onChanged: (code) {
            if (code == null) return;
            setState(() {
              _cityCode = code;
              _barangayCode = null;
              _barangays = const [];
              _error = null;
            });
            _loadBarangays(code);
          },
        ),
        const SizedBox(height: 13),
        _addressDropdown(
          label: 'Barangay',
          value: _barangayCode,
          options: _barangays,
          placeholder: _cityCode == null
              ? 'Choose a city first'
              : 'Select a barangay',
          onChanged: (code) => setState(() {
            _barangayCode = code;
            _error = null;
          }),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed:
              _busy ||
                  _regionCode == null ||
                  _provinceCode == null ||
                  _cityCode == null ||
                  _barangayCode == null
              ? null
              : _addAddress,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_location_alt_outlined),
          label: const Text('Monitor this address'),
        ),
      ],
    );
  }

  Widget _addressDropdown({
    required String label,
    required String? value,
    required List<AddressOption> options,
    required String placeholder,
    required ValueChanged<String?> onChanged,
    bool loading = false,
  }) {
    final currentValue = options.any((item) => item.code == value)
        ? value
        : null;
    return DropdownButtonFormField<String>(
      initialValue: currentValue,
      key: ValueKey('$label-$currentValue'),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: loading
            ? const Padding(
                padding: EdgeInsets.all(13),
                child: SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : null,
      ),
      hint: Text(placeholder, overflow: TextOverflow.ellipsis),
      items: options
          .map(
            (item) => DropdownMenuItem<String>(
              value: item.code,
              child: Text(item.name, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: _busy || loading || options.isEmpty ? null : onChanged,
    );
  }
}
