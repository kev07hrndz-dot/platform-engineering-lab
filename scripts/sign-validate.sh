#!/bin/sh
# Proves that signature verification rejects untrusted Zarf packages.
# It builds the package, signs it with a throwaway key pair, and fails unless:
# the signed package verifies, and an unsigned package, a package checked with
# the wrong key, and a package modified after signing are all rejected.
# No cluster is needed. The key pair is test material; releases are signed
# keylessly by the release workflow.
set -eu

version="0.1.0"
image="platform-engineering-lab:$version"
zarf="${ZARF:-zarf}"
work="build/sign"
rm -rf "$work"
mkdir -p "$work/keys" "$work/other-keys" "$work/unpacked"

# expect_rejected DESCRIPTION REASON COMMAND...: the command must fail, and its
# output must contain REASON so an unrelated error cannot pass as a rejection.
expect_rejected() {
    description="$1"
    reason="$2"
    shift 2
    if output=$("$@" 2>&1 < /dev/null); then
        echo "FAIL: $description was accepted" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -q "$reason"; then
        echo "FAIL: $description failed for an unexpected reason:" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
    echo "    rejected: $description"
}

echo "==> Building $image and the Zarf package"
docker build -q -t "$image" . > /dev/null
"$zarf" package create deploy/zarf --flavor standalone --output "$work" --confirm --log-level warn 2> /dev/null
package=$(ls "$work"/zarf-package-platform-engineering-lab-*-"$version"-standalone.tar.zst)
cp "$package" "$work/unsigned.tar.zst"

echo "==> Generating two throwaway key pairs"
helper="$(pwd)/scripts/gen-test-key.py"
(cd "$work/keys" && python3 "$helper" "$zarf")
(cd "$work/other-keys" && python3 "$helper" "$zarf")
key="$work/keys/cosign.key"
pub="$work/keys/cosign.pub"

echo "==> Signing the package"
"$zarf" package sign "$package" --signing-key "$key" --signing-key-pass "" --confirm --log-level warn < /dev/null > /dev/null 2>&1

echo "==> Verifying"
"$zarf" package verify "$package" --key "$pub" --log-level warn < /dev/null > /dev/null 2>&1
echo "    accepted: signed package with the matching public key"

expect_rejected "unsigned package" "not signed" \
    "$zarf" package verify "$work/unsigned.tar.zst" --key "$pub" --log-level warn

expect_rejected "signed package checked with a different public key" "invalid signature" \
    "$zarf" package verify "$package" --key "$work/other-keys/cosign.pub" --log-level warn

"$zarf" tools archiver decompress "$package" "$work/unpacked" --log-level warn < /dev/null > /dev/null 2>&1
sed -i.bak 's/^  version: 0\.1\.0$/  version: 9.9.9/' "$work/unpacked/zarf.yaml"
rm "$work/unpacked/zarf.yaml.bak"
grep -q '^  version: 9.9.9$' "$work/unpacked/zarf.yaml"
(cd "$work/unpacked" && "$zarf" tools archiver compress * ../tampered.tar.zst --log-level warn < /dev/null > /dev/null 2>&1)
expect_rejected "package modified after signing" "invalid signature" \
    "$zarf" package verify "$work/tampered.tar.zst" --key "$pub" --log-level warn

expect_rejected "deployment of the unsigned package with --verify=always" "not signed" \
    "$zarf" package deploy "$work/unsigned.tar.zst" --key "$pub" --verify=always --confirm --log-level warn

rm -rf "$work/keys" "$work/other-keys"
echo "Signature validation passed: 1 accepted, 4 rejected (unsigned, wrong key, tampered, unsigned deploy)"
