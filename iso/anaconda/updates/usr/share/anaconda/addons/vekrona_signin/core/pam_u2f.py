import base64
import os

from vekrona_signin.core.errors import SignInError

__all__ = ["ORIGIN", "format_u2f_line", "register"]

ORIGIN = "pam://vekrona"
ES256 = -7
COSE_X = -2
COSE_Y = -3
COSE_ALGORITHM = 3


def format_u2f_line(user, credential_id, public_key):
    raw_public_key = public_key[COSE_X] + public_key[COSE_Y]
    return ":".join([
        user,
        ",".join([
            base64.b64encode(credential_id).decode(),
            base64.b64encode(raw_public_key).decode(),
            "es256",
            "+presence",
        ]),
    ])


def register(device, pin, user, announce_touch, origin=ORIGIN):
    from fido2.ctap2 import ClientPin, Ctap2

    ctap = Ctap2(device)
    client_pin = ClientPin(ctap)
    protocol = client_pin.protocol
    client_data_hash = os.urandom(32)

    token = client_pin.get_pin_token(pin, ClientPin.PERMISSION.MAKE_CREDENTIAL, origin)
    announce_touch()
    attestation = ctap.make_credential(
        client_data_hash=client_data_hash,
        rp={"id": origin, "name": origin},
        user={"id": os.urandom(32), "name": user, "displayName": user},
        key_params=[{"type": "public-key", "alg": ES256}],
        options={"rk": False},
        pin_uv_param=protocol.authenticate(token, client_data_hash),
        pin_uv_protocol=protocol.VERSION,
    )
    credential = attestation.auth_data.credential_data
    if credential.public_key[COSE_ALGORITHM] != ES256:
        raise SignInError("The security key created a credential that is not ES256.")
    return format_u2f_line(user, credential.credential_id, credential.public_key)
