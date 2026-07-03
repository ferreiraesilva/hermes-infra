import importlib.util
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "patch_bridge_anti_ban.py"
SPEC = importlib.util.spec_from_file_location("patch_bridge_anti_ban", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


BRIDGE_FIXTURE = """
const SEND_TIMEOUT_MS = 60000;
let sock = null;
let connectionState = 'disconnected';
function sleep(ms) { return Promise.resolve(); }
function sendWithTimeout(chatId, payload, timeoutMs = SEND_TIMEOUT_MS) {
  let timer;
  const timeoutPromise = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`sendMessage timed out after ${timeoutMs / 1000}s`)),
      timeoutMs,
    );
  });
  return Promise.race([sock.sendMessage(chatId, payload), timeoutPromise])
    .finally(() => clearTimeout(timer));
}
function startSocket() {
  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect } = update;
    if (connection === 'close') {
      const reason = 500;
      connectionState = 'disconnected';
      if (reason === DisconnectReason.loggedOut) {
        process.exit(1);
      } else {
        setTimeout(startSocket, 3000);
      }
    } else if (connection === 'open') {
      connectionState = 'connected';
      if (PAIR_ONLY) {
        setTimeout(() => process.exit(0), 2000);
      }
    }
  });
}
app.get('/health', (req, res) => {
  res.json({
    status: connectionState,
    queueLength: messageQueue.length,
    uptime: process.uptime(),
  });
});
"""


def test_patch_adds_global_queue_circuit_and_health(tmp_path):
    bridge = tmp_path / "bridge.js"
    bridge.write_text(BRIDGE_FIXTURE, encoding="utf-8")

    assert MODULE.patch(bridge) is True
    patched = bridge.read_text(encoding="utf-8")

    assert MODULE.MARKER in patched
    assert "function enqueueOutbound(operation)" in patched
    assert "outboundQueueTail = run.catch" in patched
    assert "OUTBOUND_MIN_GAP_MS" in patched
    assert "SEND_FAILURE_LIMIT" in patched
    assert "RECONNECT_FAILURE_LIMIT" in patched
    assert "openOutboundCircuit(`reconnect_failures:" in patched
    assert "outboundQueueDepth," in patched
    assert "circuitRetryAfterMs" in patched


def test_patch_is_idempotent(tmp_path):
    bridge = tmp_path / "bridge.js"
    bridge.write_text(BRIDGE_FIXTURE, encoding="utf-8")
    assert MODULE.patch(bridge) is True
    first = bridge.read_text(encoding="utf-8")
    assert MODULE.patch(bridge) is False
    assert bridge.read_text(encoding="utf-8") == first
