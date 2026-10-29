class WebCoreBridge {
  WebCoreBridge._();

  static final WebCoreBridge instance = WebCoreBridge._();

  final Map<String, void Function(int pid)> _connectHandlers = {};
  final Map<String, void Function()> _disconnectHandlers = {};
  final List<void Function()> _networkChangeListeners = [];

  void addNetworkChangeListener(void Function() listener) {
    _networkChangeListeners.add(listener);
  }

  void notifyNetworkChanged() {
    for (final listener in List<void Function()>.of(_networkChangeListeners)) {
      listener();
    }
  }

  void registerServer(
    String address, {
    required void Function(int pid) onConnect,
    required void Function() onDisconnect,
  }) {
    _connectHandlers[address] = onConnect;
    _disconnectHandlers[address] = onDisconnect;
  }

  void unregisterServer(String address) {
    _connectHandlers.remove(address);
    _disconnectHandlers.remove(address);
  }

  void notifyProcessStarted(String address, int pid) {
    final handler = _connectHandlers[address];
    if (handler != null) {
      handler(pid);
    } else {
      for (final h in _connectHandlers.values) {
        h(pid);
      }
    }
  }

  void notifyProcessKilled(String address) {
    final handler = _disconnectHandlers[address];
    if (handler != null) {
      handler();
    }
  }
}

