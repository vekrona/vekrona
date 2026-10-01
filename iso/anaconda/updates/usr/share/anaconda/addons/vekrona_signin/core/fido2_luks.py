import base64
import json
import os
from dataclasses import dataclass, field

from vekrona_signin.core.errors import SignInError

__all__ = ["RP_ID", "FidoLuksEnrollment", "enroll", "passphrase", "token_json"]

RP_ID = "io.systemd.cryptsetup"
CREDENTIAL_USER_ID = b"vekrona"
CLIENT_DATA_HASH = bytes(32)
ES256 = -7
SECRET_LENGTH = 32


@dataclass(frozen=True)
class FidoLuksEnrollment:
    credential_id: bytes = field(repr=False)
    salt: bytes = field(repr=False)
    secret: bytes = field(repr=False)


def passphrase(enrollment):
    return base64.b64encode(enrollment.secret).decode()


def token_json(enrollment, keyslot):
    return json.dumps({
        "type": "systemd-fido2",
        "keyslots": [str(keyslot)],
        "fido2-credential": base64.b64encode(enrollment.credential_id).decode(),
        "fido2-salt": base64.b64encode(enrollment.salt).decode(),
        "fido2-rp": RP_ID,
        "fido2-clientPin-required": True,
        "fido2-up-required": True,
        "fido2-uv-required": False,
    })


def enroll(device, pin, set_pin, announce_touch):
    from fido2.ctap2 import ClientPin, Ctap2

    ctap = Ctap2(device)
    options = ctap.info.options
    if "hmac-secret" not in ctap.info.extensions:
        raise SignInError("This security key does not support the hmac-secret extension.")
    if "clientPin" not in options:
        raise SignInError("This security key does not support a PIN.")
    client_pin = ClientPin(ctap)
    if set_pin:
        if options["clientPin"]:
            raise SignInError("This security key already has a PIN.")
        client_pin.set_pin(pin)
    elif not options["clientPin"]:
        raise SignInError("This security key has no PIN yet; choose a new PIN for it.")
    protocol = client_pin.protocol

    token = client_pin.get_pin_token(pin, ClientPin.PERMISSION.MAKE_CREDENTIAL, RP_ID)
    announce_touch()
    attestation = ctap.make_credential(
        client_data_hash=CLIENT_DATA_HASH,
        rp={"id": RP_ID, "name": RP_ID},
        user={"id": CREDENTIAL_USER_ID, "name": "vekrona", "displayName": "vekrona"},
        key_params=[{"type": "public-key", "alg": ES256}],
        extensions={"hmac-secret": True},
        options={"rk": False},
        pin_uv_param=protocol.authenticate(token, CLIENT_DATA_HASH),
        pin_uv_protocol=protocol.VERSION,
    )
    if attestation.auth_data.extensions.get("hmac-secret") is not True:
        raise SignInError("The security key did not enable the hmac-secret extension.")
    credential_id = attestation.auth_data.credential_data.credential_id

    token = client_pin.get_pin_token(pin, ClientPin.PERMISSION.GET_ASSERTION, RP_ID)
    key_agreement, shared_secret = client_pin._get_shared_secret()
    salt = os.urandom(SECRET_LENGTH)
    salt_enc = protocol.encrypt(shared_secret, salt)
    salt_auth = protocol.authenticate(shared_secret, salt_enc)
    announce_touch()
    assertion = ctap.get_assertion(
        RP_ID,
        CLIENT_DATA_HASH,
        allow_list=[{"type": "public-key", "id": credential_id}],
        extensions={"hmac-secret": {1: key_agreement, 2: salt_enc, 3: salt_auth, 4: protocol.VERSION}},
        options={"up": True},
        pin_uv_param=protocol.authenticate(token, CLIENT_DATA_HASH),
        pin_uv_protocol=protocol.VERSION,
    )
    secret = protocol.decrypt(shared_secret, assertion.auth_data.extensions["hmac-secret"])
    if len(secret) != SECRET_LENGTH:
        raise SignInError("The security key returned an hmac-secret of unexpected length.")
    return FidoLuksEnrollment(credential_id=credential_id, salt=salt, secret=secret)
