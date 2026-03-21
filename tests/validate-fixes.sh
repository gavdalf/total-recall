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

# Exit with error code if any tests failed
if [ "$FAILURES" -gt 0 ]; then
    echo "❌ $FAILURES test(s) failed"
    exit 1
else
    echo "✅ All tests passed"
    exit 0
fi
