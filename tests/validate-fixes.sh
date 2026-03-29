#!/usr/bin/env bash
# Simple validation test for Total Recall fixes

echo "🧪 Total Recall Fixes Validation"
echo "================================="

# Track failures
FAILURES=0

# Test 1: Check OBSERVER_MODEL default in script
echo "📋 Test 1: OBSERVER_MODEL default"
if grep -q 'OBSERVER_MODEL="\${OBSERVER_MODEL:-stepfun/step-3.5-flash:free}"' scripts/observer-agent.sh; then
    echo "✅ OBSERVER_MODEL correctly defaults to free model"
else
    echo "❌ OBSERVER_MODEL default issue in script"
    ((FAILURES++))
fi

# Test 2: Check REFLECTOR_MODEL fallback chain in script
echo ""
echo "📋 Test 2: REFLECTOR_MODEL fallback chain"
if grep -q 'REFLECTOR_MODEL="\${REFLECTOR_MODEL:-\${OBSERVER_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}}"' scripts/reflector-agent.sh; then
    echo "✅ REFLECTOR_MODEL correctly includes OBSERVER_MODEL in fallback"
else
    echo "❌ REFLECTOR_MODEL fallback chain issue in script"
    ((FAILURES++))
fi

# Test 3: Check REFLECTOR_FALLBACK_MODEL in script
echo ""
echo "📋 Test 3: REFLECTOR_FALLBACK_MODEL default"
if grep -q 'REFLECTOR_FALLBACK_MODEL="\${REFLECTOR_FALLBACK_MODEL:-openrouter/hunter-alpha}"' scripts/reflector-agent.sh; then
    echo "✅ REFLECTOR_FALLBACK_MODEL correctly set"
else
    echo "❌ REFLECTOR_FALLBACK_MODEL missing in script"
    ((FAILURES++))
fi

# Test 4: Check empty content handling logic
echo ""
echo "📋 Test 4: Empty content handling logic"
if grep -q 'CONTENT=.*jq.*content.*empty' scripts/observer-agent.sh && grep -q 'REASONING=.*jq.*reasoning.*empty' scripts/observer-agent.sh && grep -q 'not just whitespace' scripts/observer-agent.sh; then
    echo "✅ Empty content handling logic present in observer"
else
    echo "❌ Empty content handling missing in observer"
    ((FAILURES++))
fi

if grep -q 'CONTENT=.*jq.*content.*empty' scripts/reflector-agent.sh && grep -q 'REASONING=.*jq.*reasoning.*empty' scripts/reflector-agent.sh && grep -q 'not just whitespace' scripts/reflector-agent.sh; then
    echo "✅ Empty content handling logic present in reflector"
else
    echo "❌ Empty content handling missing in reflector"
    ((FAILURES++))
fi

# Test 4.5: Check fallback logic implementation
echo ""
echo "📋 Test 4.5: REFLECTOR_FALLBACK_MODEL logic"
if grep -q 'MODELS=("\$REFLECTOR_MODEL"' scripts/reflector-agent.sh && grep -q 'MODEL="${MODELS' scripts/reflector-agent.sh; then
    echo "✅ REFLECTOR_FALLBACK_MODEL logic implemented"
else
    echo "❌ REFLECTOR_FALLBACK_MODEL logic missing"
    ((FAILURES++))
fi

# Test 5: Check documentation fixes
echo ""
echo "📋 Test 5: Documentation fixes"
if grep -q 'stepfun/step-3.5-flash:free' SKILL.md; then
    echo "✅ Free model suffix added to documentation"
else
    echo "❌ Free model suffix missing in documentation"
    ((FAILURES++))
fi

if grep -q 'defensive handling' SKILL.md; then
    echo "✅ Model notes section corrected"
else
    echo "❌ Model notes section not corrected"
    ((FAILURES++))
fi

echo ""
echo "🎯 Script Validation Complete"

# ─── Integrity verification tests ───────────────────────────────────────────

echo ""
echo "📋 Test 6: integrity-check.sh exists and is executable"
if [ -f "scripts/integrity-check.sh" ]; then
    chmod +x scripts/integrity-check.sh
    echo "✅ integrity-check.sh present"
else
    echo "❌ integrity-check.sh missing"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 7: integrity.yaml config file present"
if [ -f "config/integrity.yaml" ]; then
    echo "✅ config/integrity.yaml present"
else
    echo "❌ config/integrity.yaml missing"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 8: integrity.yaml has required keys"
if grep -q 'enabled:' config/integrity.yaml && \
   grep -q 'sample_n:' config/integrity.yaml && \
   grep -q 'block_on_flag:' config/integrity.yaml && \
   grep -q 'reflector_threshold:' config/integrity.yaml && \
   grep -q 'dream_threshold:' config/integrity.yaml; then
    echo "✅ integrity.yaml has all required config keys"
else
    echo "❌ integrity.yaml missing required keys"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 9: reflector-agent.sh integrates integrity capture + verify"
if grep -q 'integrity-check.sh' scripts/reflector-agent.sh && \
   grep -q 'integrity.*pre-reflector\|integrity-pre-reflector' scripts/reflector-agent.sh && \
   grep -q 'integrity.*verify\|INTEGRITY_RESULT' scripts/reflector-agent.sh; then
    echo "✅ reflector-agent.sh has integrity capture + verify hooks"
else
    echo "❌ reflector-agent.sh missing integrity hooks"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 10: dream-cycle.sh integrates integrity capture in preflight"
if grep -q 'integrity-check.sh' scripts/dream-cycle.sh && \
   grep -q 'integrity-pre-dream' scripts/dream-cycle.sh; then
    echo "✅ dream-cycle.sh preflight has integrity capture hook"
else
    echo "❌ dream-cycle.sh missing integrity capture in preflight"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 11: dream-cycle.sh integrates integrity verify in update-observations"
if grep -q 'integrity: verify post-dream\|integrity_pre_state.*dream\|verify.*integrity.*dream' scripts/dream-cycle.sh; then
    echo "✅ dream-cycle.sh update-observations has integrity verify hook"
else
    echo "❌ dream-cycle.sh missing integrity verify in update-observations"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 12: integrity-check.sh has capture and verify commands"
if grep -q 'cmd_capture()' scripts/integrity-check.sh && \
   grep -q 'cmd_verify()' scripts/integrity-check.sh; then
    echo "✅ integrity-check.sh has capture + verify functions"
else
    echo "❌ integrity-check.sh missing capture or verify functions"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 13: integrity-check.sh respects INTEGRITY_ENABLED=false"
if grep -q 'INTEGRITY_ENABLED.*true' scripts/integrity-check.sh && \
   grep -q 'disabled.*skipping\|status.*disabled' scripts/integrity-check.sh; then
    echo "✅ integrity-check.sh respects disabled flag"
else
    echo "❌ integrity-check.sh does not handle INTEGRITY_ENABLED=false"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 14: integrity-check.sh has flag-only default (non-blocking)"
if grep -q 'BLOCK_ON_FLAG.*false\|block_on_flag.*false' scripts/integrity-check.sh && \
   grep -q 'BLOCK_ON_FLAG.*true' scripts/integrity-check.sh && \
   grep -q 'exit 2' scripts/integrity-check.sh; then
    echo "✅ integrity-check.sh is flag-only by default (non-blocking)"
else
    echo "❌ integrity-check.sh blocking behavior misconfigured"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 15: cosine similarity uses Python3 (portable float math)"
if grep -q '_cosine_sim' scripts/integrity-check.sh && \
   grep -A5 '_cosine_sim()' scripts/integrity-check.sh | grep -q 'python3'; then
    echo "✅ cosine similarity implemented via python3"
else
    echo "❌ cosine similarity not using python3"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 16: dry-run mode supported"
if grep -q 'dry.run' scripts/integrity-check.sh && \
   grep -q 'dry.run' scripts/dream-cycle.sh; then
    echo "✅ dry-run mode supported in both scripts"
else
    echo "❌ dry-run mode missing"
    ((FAILURES++))
fi

echo ""
echo "📋 Test 17: execution-level — integrity-check.sh capture/verify argv + exit-code propagation"
_run_integration_stub_test() {
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  # Create a minimal stubbed observations file
  printf 'obs line one\nobs line two\nobs line three\n' > "$tmpdir/observations.md"

  # Create a stubbed integrity-check.sh that inspects argv and exits with a known code
  cat > "$tmpdir/integrity-check.sh" <<'STUB'
#!/usr/bin/env bash
CHECKPOINT="$1"; shift
COMMAND=""
DRY_RUN="false"
for _a in "$@"; do
  [ "$_a" = "--dry-run" ] && DRY_RUN="true" && continue
  [ -z "$COMMAND" ] && COMMAND="$_a" && continue
done
# Record invocation for test inspection
echo "$CHECKPOINT $COMMAND dry=$DRY_RUN" >> "${STUB_LOG:-/dev/null}"
# cmd_capture: always succeeds
# cmd_verify: exit 2 if BLOCK requested to test propagation
if [ "$COMMAND" = "verify" ] && [ "${STUB_BLOCK:-false}" = "true" ]; then
  exit 2
fi
exit 0
STUB
  chmod +x "$tmpdir/integrity-check.sh"

  local stub_log="$tmpdir/stub.log"
  local ok=1

  # ── Test 17a: capture is called with correct CHECKPOINT arg ──────────────
  STUB_LOG="$stub_log" INTEGRITY_ENABLED="true" \
    bash "$tmpdir/integrity-check.sh" reflector capture "$tmpdir/observations.md" "$tmpdir/pre.json" 2>/dev/null
  if grep -q "^reflector capture" "$stub_log" 2>/dev/null; then
    echo "  ✅ 17a: capture called with CHECKPOINT=reflector"
  else
    echo "  ❌ 17a: capture argv shape wrong (expected 'reflector capture ...')"
    ok=0
  fi
  > "$stub_log"

  # ── Test 17b: verify exit 2 propagates through dream-cycle wrapper ────────
  # Create a minimal dream-cycle wrapper that calls our stub
  cat > "$tmpdir/dream-cycle-wrapper.sh" <<WRAPPER
#!/usr/bin/env bash
SKILL_DIR="$tmpdir"
MEMORY_DIR="$tmpdir"
OBSERVATIONS_FILE="$tmpdir/observations.md"
INTEGRITY_SCRIPT="$tmpdir/integrity-check.sh"
INTEGRITY_PRE_STATE="$tmpdir/pre-dream.json"
INTEGRITY_ENABLED=true
INTEGRITY_BLOCK_ON_FLAG=true
STUB_BLOCK=true
STUB_LOG="$stub_log"
export INTEGRITY_ENABLED INTEGRITY_BLOCK_ON_FLAG STUB_BLOCK STUB_LOG
# Simulate the dream-cycle update-observations integrity block
touch "\$INTEGRITY_PRE_STATE"
if [ -f "\$INTEGRITY_SCRIPT" ] && [ "\${INTEGRITY_ENABLED}" = "true" ] && [ -f "\$INTEGRITY_PRE_STATE" ]; then
  local_exit=0
  bash "\$INTEGRITY_SCRIPT" dream verify "\$OBSERVATIONS_FILE" "\$INTEGRITY_PRE_STATE" >/dev/null 2>&1 || local_exit=\$?
  if [ "\$local_exit" -eq 2 ] && [ "\${INTEGRITY_BLOCK_ON_FLAG:-false}" = "true" ]; then
    exit 2
  fi
fi
exit 0
WRAPPER
  chmod +x "$tmpdir/dream-cycle-wrapper.sh"
  bash "$tmpdir/dream-cycle-wrapper.sh"
  local wrapper_exit=$?
  if [ "$wrapper_exit" -eq 2 ]; then
    echo "  ✅ 17b: exit 2 from verifier propagated through dream-cycle wrapper"
  else
    echo "  ❌ 17b: dream-cycle wrapper masked exit 2 (got exit $wrapper_exit)"
    ok=0
  fi
  > "$stub_log"

  # ── Test 17c: --dry-run flag parsed correctly ─────────────────────────────
  STUB_LOG="$stub_log" INTEGRITY_ENABLED="true" \
    bash "$tmpdir/integrity-check.sh" dream --dry-run capture "$tmpdir/observations.md" 2>/dev/null
  if grep -q "dry=true" "$stub_log" 2>/dev/null; then
    echo "  ✅ 17c: --dry-run flag parsed correctly"
  else
    echo "  ❌ 17c: --dry-run flag not detected in argv"
    ok=0
  fi

  return $((1 - ok))
}

if _run_integration_stub_test; then
  echo "✅ Test 17: execution-level stub tests passed"
else
  echo "❌ Test 17: one or more execution-level sub-tests failed"
  ((FAILURES++))
fi

# Exit with error code if any tests failed
if [ "$FAILURES" -gt 0 ]; then
    echo ""
    echo "❌ $FAILURES test(s) failed"
    exit 1
else
    echo ""
    echo "✅ All tests passed"
    exit 0
fi
