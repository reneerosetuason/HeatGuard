import 'package:flutter/material.dart';

import '../services/mobile_auth_controller.dart';
import '../widgets/heatguard_brand.dart';
import 'auth_screen.dart';
import 'dashboard_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, this.controller});
  final MobileAuthController? controller;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final MobileAuthController _auth;
  @override
  void initState() {
    super.initState();
    _auth = widget.controller ?? MobileAuthController();
    _auth.initialize();
  }

  @override
  void dispose() {
    if (widget.controller == null) _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _auth,
    builder: (context, _) {
      if (_auth.initializing) {
        return const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                HeatGuardLogo(width: 200),
                SizedBox(height: 22),
                Text(
                  'Welcome to HeatGuard',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 20),
                CircularProgressIndicator(),
              ],
            ),
          ),
        );
      }
      final account = _auth.account;
      if (account == null) return AuthScreen(controller: _auth);
      return HeroControllerScope.none(
        child: Navigator(
          key: ValueKey('${_auth.baseUrl}/${account.id}'),
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => DashboardScreen(
              api: _auth.api,
              account: account,
              onAccountSignOut: _auth.signOut,
              onServerChanged: _auth.changeServer,
            ),
          ),
        ),
      );
    },
  );
}
