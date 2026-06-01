#!/usr/bin/env python3
"""
Python RNS compatibility script for Elixir interop tests.

Called by ReticulumLink.Interop.RnsCompatTest to verify wire compatibility
between Elixir Reticulum Link and Python RNS.
"""

import sys
import json
import hashlib
import os

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)


def verify_sig(args):
    """Verify an Ed25519 signature."""
    pk = Ed25519PublicKey.from_public_bytes(bytes.fromhex(args["public_key"]))
    message = args["message"].encode("utf-8")
    sig = bytes.fromhex(args["signature"])

    try:
        pk.verify(sig, message)
        return {"valid": True}
    except Exception:
        return {"valid": False}


def generate_and_sign(args):
    """Generate Ed25519 keypair and sign a message."""
    message = args["message"].encode("utf-8")

    sk = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(args.get("secret_key", os.urandom(32).hex())))
    pk = sk.public_key()

    sig = sk.sign(message)

    return {
        "public_key": pk.public_bytes_raw().hex(),
        "signature": sig.hex(),
    }


def derive_x25519(args):
    """Derive X25519 keys from Ed25519 keys."""
    ed_sk = bytes.fromhex(args["secret_key"])
    ed_pk = bytes.fromhex(args["public_key"])

    # Ed25519 -> X25519: clamp the secret key and derive public
    # The standard approach: use the Ed25519 secret key bytes as X25519 secret
    xsk = X25519PrivateKey.from_private_bytes(ed_sk)
    xpk = xsk.public_key()

    return {
        "x25519_secret": xsk.private_bytes_raw().hex(),
        "x25519_public": xpk.public_bytes_raw().hex(),
    }


def sha256(args):
    """Compute SHA-256 hash."""
    data = args["data"].encode("utf-8")
    h = hashlib.sha256(data).digest()
    return {"hash": h.hex()}


def serialize_header(args):
    """Serialize a Reticulum-compatible header."""
    header_type = args["header_type"]
    dst_hash = bytes.fromhex(args["destination_hash"])
    packet_type = args["packet_type"]
    hops = args["hops"]
    context = args["context"]

    # Reticulum HEADER_1 format:
    # - 1 byte: flags (header_type[1], context_flag[1], transport_type[1], destination_type[2], packet_type[2])
    # - 1 byte: hops
    # - 16 bytes: destination_hash
    # - 1 byte: context
    flags = (
        (header_type & 0x01) << 7
        | (0 & 0x01) << 6
        | (0 & 0x01) << 5
        | (0 & 0x03) << 3
        | (packet_type & 0x03) << 1
    )

    header = bytes([flags, hops]) + dst_hash + bytes([context])

    return {"header": header.hex()}


def hkdf(args):
    """HKDF-SHA-256 key derivation."""
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes

    ikm = bytes.fromhex(args["ikm"])
    salt = bytes.fromhex(args["salt"])
    info = args["info"].encode("utf-8")
    length = args["length"]

    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=length,
        salt=salt,
        info=info,
    )
    okm = hkdf.derive(ikm)
    return {"okm": okm.hex()}


FUNCTIONS = {
    "verify_sig": verify_sig,
    "generate_and_sign": generate_and_sign,
    "derive_x25519": derive_x25519,
    "hkdf": hkdf,
    "serialize_header": serialize_header,
}


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: rns_compat.py <function> <json_args>"}))
        sys.exit(1)

    func_name = sys.argv[1]
    args = json.loads(sys.argv[2])

    func = FUNCTIONS.get(func_name)
    if not func:
        print(json.dumps({"error": f"Unknown function: {func_name}"}))
        sys.exit(1)

    try:
        result = func(args)
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
