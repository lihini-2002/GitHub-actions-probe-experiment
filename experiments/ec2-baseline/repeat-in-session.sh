# Paste/source in an existing interactive Session Manager shell after sudo -iu ubuntu.
# For the final tenth new run, the same loop was pasted with only 011.
# Intentionally not an executable harness: npm's parent stays the interactive bash.
cd /home/ubuntu/research/GitHub-actions-probe-experiment
set -o pipefail
for baseline_number in 002 003 004 005 006 007 008 009 010; do
  baseline_dir="/home/ubuntu/research/results/ec2/baseline/run-${baseline_number}"
  mkdir -m 700 "$baseline_dir" || break
  { date -u --iso-8601=seconds; id; tty; pwd; git rev-parse HEAD; sha256sum packages/npm-probing-package-0.1.0.tgz package-lock.json; node --version; npm --version; uname -a; } > "$baseline_dir/context.txt"
  npm ci 2>&1 | tee "$baseline_dir/npm-ci.log"
  baseline_ci=$?
  npm test 2>&1 | tee "$baseline_dir/npm-test.log"
  baseline_test=$?
  npm run build 2>&1 | tee "$baseline_dir/npm-build.log"
  baseline_build=$?
  printf '{"npm_ci":%s,"npm_test":%s,"npm_build":%s}\n' "$baseline_ci" "$baseline_test" "$baseline_build" > "$baseline_dir/exit-codes.json"
  cp node_modules/npm-probing-package/results/install-*.json "$baseline_dir/"
  printf 'BASELINE_RUN_%s_RECORDED\n' "$baseline_number"
done
