// Mint a DataLens On-premises access token from a service-account private key.
// Flow (per on-prem docs): sign a PS256 JWT with the SA key, then exchange it
// at /rpc/exchangeServiceAccountToken for an accessToken usable as Bearer.
//
// Usage:
//   DL_HOST=https://<domain> DL_SA_ID=<sa-id> DL_KEY_ID=<key-id> \
//   DL_KEY_PATH=<key.pem> node onprem_mint_token.mjs
//
// Prints the accessToken to stdout. Diagnostics go to stderr.
import {readFileSync} from 'node:fs';
import {createSign, constants} from 'node:crypto';

const HOST = process.env.DL_HOST;
const SA_ID = process.env.DL_SA_ID;
const KEY_ID = process.env.DL_KEY_ID;
const KEY_PATH = process.env.DL_KEY_PATH;
const API_VERSION = process.env.DL_API_VERSION || '2';

for (const [name, val] of [['DL_HOST', HOST], ['DL_SA_ID', SA_ID], ['DL_KEY_ID', KEY_ID], ['DL_KEY_PATH', KEY_PATH]]) {
    if (!val) {
        process.stderr.write(`[mint] missing env ${name}\n`);
        process.exit(2);
    }
}

const b64url = (buf) =>
    Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function signJwt(privateKey) {
    const now = Math.floor(Date.now() / 1000);
    const header = {alg: 'PS256', typ: 'JWT', kid: KEY_ID};
    const payload = {iss: SA_ID, iat: now, exp: now + 300}; // max lifetime 10 min; we use 5
    const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
    const signer = createSign('RSA-SHA256');
    signer.update(signingInput);
    const signature = signer.sign(
        {key: privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32},
        'base64',
    );
    const sigUrl = signature.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    return `${signingInput}.${sigUrl}`;
}

async function main() {
    const privateKey = readFileSync(KEY_PATH, 'utf8');
    const saToken = signJwt(privateKey);
    process.stderr.write(`[mint] signed JWT for sa=${SA_ID} kid=${KEY_ID}\n`);

    const res = await fetch(`${HOST}/rpc/exchangeServiceAccountToken`, {
        method: 'POST',
        headers: {'content-type': 'application/json', 'x-dl-api-version': API_VERSION},
        body: JSON.stringify({saToken}),
    });
    const text = await res.text();
    if (!res.ok) {
        process.stderr.write(`[mint] exchange failed: HTTP ${res.status}\n${text}\n`);
        process.exit(1);
    }
    const {accessToken} = JSON.parse(text);
    process.stderr.write(`[mint] got accessToken (${accessToken.length} chars)\n`);
    process.stdout.write(accessToken);
}

main().catch((e) => {
    process.stderr.write(`[mint] error: ${e.stack || e}\n`);
    process.exit(1);
});
