import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mobile_account.dart';
import '../services/heatguard_api.dart';
import '../services/mobile_auth_controller.dart';
import '../theme/heatguard_theme.dart';

enum _AuthStep { signIn, register, verify }

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.controller});
  final MobileAuthController controller;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _code = TextEditingController();
  _AuthStep _step = _AuthStep.signIn;
  RegistrationChallenge? _challenge;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;
  DateTime? _resendAt;
  Timer? _countdown;

  int get _remaining =>
      (_resendAt?.difference(DateTime.now()).inSeconds ?? 0).clamp(0, 3600);

  @override
  void dispose() {
    _countdown?.cancel();
    for (final controller in [_name, _email, _password, _confirmation, _code]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _changeStep(_AuthStep step) {
    _countdown?.cancel();
    setState(() {
      _step = step;
      _error = null;
      _showPassword = false;
    });
  }

  void _showChallenge(RegistrationChallenge challenge) {
    _countdown?.cancel();
    _code.clear();
    setState(() {
      _challenge = challenge;
      _step = _AuthStep.verify;
      _resendAt = DateTime.now().add(
        Duration(seconds: challenge.resendAfter + 1),
      );
      _error = null;
    });
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _remaining == 0) timer.cancel();
      if (mounted) setState(() {});
    });
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (_step) {
        case _AuthStep.signIn:
          await widget.controller.signIn(_email.text.trim(), _password.text);
          TextInput.finishAutofillContext();
        case _AuthStep.register:
          final challenge = await widget.controller.register(
            name: _name.text.trim(),
            email: _email.text.trim(),
            password: _password.text,
          );
          if (mounted) _showChallenge(challenge);
        case _AuthStep.verify:
          await widget.controller.verify(_challenge!, _code.text.trim());
          TextInput.finishAutofillContext();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    if (_busy || _remaining > 0 || _challenge == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = await widget.controller.resend(_challenge!);
      if (mounted) {
        _showChallenge(challenge);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A new code is on its way. Use the latest email.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object error) => error is HeatGuardApiException
      ? error.message
      : 'We could not complete that request. Please try again.';

  Future<void> _serverSettings() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _ServerAddressDialog(address: widget.controller.baseUrl),
    );
    if (value == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.changeServer(value);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verification = _step == _AuthStep.verify;
    final registration = _step == _AuthStep.register;
    final error = _error ?? widget.controller.connectionError;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(26, 24, 26, 28),
              child: AutofillGroup(
                onDisposeAction: AutofillContextAction.cancel,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: HeatGuardColors.teal,
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: const Icon(
                            Icons.shield_outlined,
                            color: Colors.white,
                            size: 25,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Text(
                            'HeatGuard',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Server settings',
                          onPressed: _busy ? null : _serverSettings,
                          icon: const Icon(
                            Icons.tune_rounded,
                            color: HeatGuardColors.muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 36),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: verification
                            ? HeatGuardColors.sand
                            : HeatGuardColors.mint,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Icon(
                        verification
                            ? Icons.mark_email_unread_outlined
                            : registration
                            ? Icons.person_add_alt_1_outlined
                            : Icons.wb_sunny_outlined,
                        size: 32,
                        color: HeatGuardColors.teal,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      verification
                          ? 'ONE LAST STEP'
                          : 'A LITTLE AWARENESS. A SAFER DAY.',
                      style: const TextStyle(
                        color: HeatGuardColors.teal,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      verification
                          ? 'Check your inbox.'
                          : registration
                          ? 'Make safer days yours.'
                          : 'Welcome back.',
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      verification
                          ? 'Enter the six-digit code sent to ${_challenge!.email} to finish creating your account.'
                          : registration
                          ? 'Create your account, verify your email, and stay a step ahead of the heat.'
                          : 'Sign in for your local conditions, heat alerts, and a little peace of mind.',
                      style: const TextStyle(
                        color: HeatGuardColors.muted,
                        fontSize: 14,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 26),
                    if (error != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF0E2),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            error,
                            style: const TextStyle(
                              color: Color(0xFF874C22),
                              fontSize: 13,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],
                    Form(
                      key: _form,
                      child: KeyedSubtree(
                        key: ValueKey(_step),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (verification) ...[
                              TextFormField(
                                key: const ValueKey('auth-code'),
                                controller: _code,
                                enabled: !_busy,
                                autofocus: true,
                                keyboardType: TextInputType.number,
                                textInputAction: TextInputAction.done,
                                autofillHints: const [
                                  AutofillHints.oneTimeCode,
                                ],
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(6),
                                ],
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 27,
                                  letterSpacing: 10,
                                  color: HeatGuardColors.ink,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Verification code',
                                  hintText: '000000',
                                ),
                                validator: (value) =>
                                    RegExp(r'^[0-9]{6}$').hasMatch(value ?? '')
                                    ? null
                                    : 'Enter the six-digit code.',
                                onFieldSubmitted: (_) => _submit(),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Your code expires in 10 minutes. Check spam if it has not arrived.',
                                style: TextStyle(
                                  color: HeatGuardColors.muted,
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                            ] else ...[
                              if (registration) ...[
                                TextFormField(
                                  key: const ValueKey('auth-name'),
                                  controller: _name,
                                  enabled: !_busy,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.next,
                                  autofillHints: const [AutofillHints.name],
                                  maxLength: 80,
                                  decoration: const InputDecoration(
                                    labelText: 'Your name',
                                    prefixIcon: Icon(
                                      Icons.person_outline_rounded,
                                    ),
                                    counterText: '',
                                  ),
                                  validator: (value) =>
                                      (value ?? '').trim().isEmpty
                                      ? 'Enter your name.'
                                      : null,
                                ),
                                const SizedBox(height: 16),
                              ],
                              TextFormField(
                                key: const ValueKey('auth-email'),
                                controller: _email,
                                enabled: !_busy,
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                autocorrect: false,
                                autofillHints: const [AutofillHints.email],
                                maxLength: 254,
                                decoration: const InputDecoration(
                                  labelText: 'Email address',
                                  prefixIcon: Icon(
                                    Icons.alternate_email_rounded,
                                  ),
                                  counterText: '',
                                ),
                                validator: (value) =>
                                    RegExp(
                                      r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                    ).hasMatch((value ?? '').trim())
                                    ? null
                                    : 'Enter a valid email address.',
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                key: const ValueKey('auth-password'),
                                controller: _password,
                                enabled: !_busy,
                                obscureText: !_showPassword,
                                autocorrect: false,
                                enableSuggestions: false,
                                textInputAction: registration
                                    ? TextInputAction.next
                                    : TextInputAction.done,
                                autofillHints: [
                                  registration
                                      ? AutofillHints.newPassword
                                      : AutofillHints.password,
                                ],
                                maxLength: 128,
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  counterText: '',
                                  helperText: registration
                                      ? 'Use 12 or more characters.'
                                      : null,
                                  prefixIcon: const Icon(
                                    Icons.lock_outline_rounded,
                                  ),
                                  suffixIcon: IconButton(
                                    tooltip: _showPassword
                                        ? 'Hide password'
                                        : 'Show password',
                                    onPressed: () => setState(
                                      () => _showPassword = !_showPassword,
                                    ),
                                    icon: Icon(
                                      _showPassword
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                    ),
                                  ),
                                ),
                                validator: (value) => (value ?? '').isEmpty
                                    ? 'Enter your password.'
                                    : registration && value!.length < 12
                                    ? 'Use at least 12 characters.'
                                    : null,
                                onFieldSubmitted: registration
                                    ? null
                                    : (_) => _submit(),
                              ),
                              if (registration) ...[
                                const SizedBox(height: 16),
                                TextFormField(
                                  key: const ValueKey('auth-confirmation'),
                                  controller: _confirmation,
                                  enabled: !_busy,
                                  obscureText: !_showPassword,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  maxLength: 128,
                                  autofillHints: const [
                                    AutofillHints.newPassword,
                                  ],
                                  textInputAction: TextInputAction.done,
                                  decoration: const InputDecoration(
                                    labelText: 'Confirm password',
                                    prefixIcon: Icon(
                                      Icons.lock_outline_rounded,
                                    ),
                                    counterText: '',
                                  ),
                                  validator: (value) => value != _password.text
                                      ? 'Your passwords do not match.'
                                      : null,
                                  onFieldSubmitted: (_) => _submit(),
                                ),
                              ],
                            ],
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: _busy ? null : _submit,
                              iconAlignment: IconAlignment.end,
                              icon: _busy
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.arrow_forward_rounded,
                                      size: 19,
                                    ),
                              label: Text(
                                _busy
                                    ? 'Please wait...'
                                    : verification
                                    ? 'Verify & continue'
                                    : registration
                                    ? 'Send verification code'
                                    : 'Sign in',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (verification) ...[
                      Center(
                        child: TextButton(
                          onPressed: _busy || _remaining > 0 ? null : _resend,
                          child: Text(
                            _remaining > 0
                                ? 'Resend code in ${_remaining}s'
                                : 'Resend code',
                          ),
                        ),
                      ),
                      Center(
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () => _changeStep(_AuthStep.register),
                          child: const Text('Use another email'),
                        ),
                      ),
                    ] else
                      Center(
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              registration
                                  ? 'Already have an account?'
                                  : 'New to HeatGuard?',
                              style: const TextStyle(
                                color: HeatGuardColors.muted,
                                fontSize: 13,
                              ),
                            ),
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _changeStep(
                                      registration
                                          ? _AuthStep.signIn
                                          : _AuthStep.register,
                                    ),
                              child: Text(
                                registration ? 'Sign in' : 'Create account',
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 20),
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.verified_user_outlined,
                          color: HeatGuardColors.muted,
                          size: 16,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'A verified email keeps your account yours. Sign in to access HeatGuard.',
                            style: TextStyle(
                              color: HeatGuardColors.muted,
                              fontSize: 11,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerAddressDialog extends StatefulWidget {
  const _ServerAddressDialog({required this.address});
  final String address;
  @override
  State<_ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<_ServerAddressDialog> {
  late final _address = TextEditingController(text: widget.address);
  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('HeatGuard server'),
    content: TextField(
      controller: _address,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(labelText: 'API base address'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _address.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}
