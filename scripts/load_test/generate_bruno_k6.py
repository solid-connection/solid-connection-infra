#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


HTTP_METHODS = ("get", "post", "put", "patch", "delete", "options", "head")
LOGIN_PATH = "/auth/email/sign-in"
TOKEN_ENDING_PATHS = ("/auth/sign-out", "/auth/quit")
DESTRUCTIVE_PATHS = ("/auth/quit",)


def brace_delta(line):
    """Return the net brace balance contributed by a single Bruno line."""
    return line.count("{") - line.count("}")


def read_text(path):
    """Read a Bruno file while tolerating invalid byte sequences."""
    return path.read_text(encoding="utf-8", errors="replace")


def collect_blocks(text):
    """Collect top-level Bruno blocks keyed by block name."""
    lines = text.splitlines()
    blocks = {}
    index = 0

    while index < len(lines):
        line = lines[index]
        match = re.match(r"^\s*([A-Za-z0-9_:-]+)\s*\{\s*$", line)
        if not match:
            index += 1
            continue

        block_name = match.group(1)
        body = []
        balance = brace_delta(line)
        index += 1

        while index < len(lines):
            current = lines[index]
            next_balance = balance + brace_delta(current)
            if next_balance <= 0 and current.strip() == "}":
                index += 1
                break
            body.append(current)
            balance = next_balance
            index += 1

        blocks.setdefault(block_name, []).append("\n".join(body).strip("\n"))

    return blocks


def parse_fields(block):
    """Parse simple Bruno key-value fields from a block body."""
    fields = {}
    for line in block.splitlines():
        match = re.match(r"^\s*(~?[^:]+):\s*(.*)$", line)
        if match:
            key = match.group(1).strip()
            value = match.group(2).strip()
            fields[key] = value
    return fields


def parse_meta(blocks):
    """Extract display metadata and sort order from parsed Bruno blocks."""
    meta = parse_fields(blocks.get("meta", [""])[0])
    seq = meta.get("seq", "999999")
    try:
        seq_number = int(seq)
    except ValueError:
        seq_number = 999999
    return {
        "name": meta.get("name", ""),
        "seq": seq_number,
    }


def parse_vars(blocks):
    """Extract pre-request variables defined in Bruno request blocks."""
    variables = {}
    for block in blocks.get("vars:pre-request", []):
        for key, value in parse_fields(block).items():
            variables[key.lstrip("~")] = value
    return variables


def clean_body_json(block):
    """Return the JSON body text exactly as k6 should send it."""
    return block.strip()


def parse_multipart(block):
    """Parse Bruno multipart form fields into k6-friendly metadata."""
    fields = []
    for line in block.splitlines():
        match = re.match(r"^\s*(~?[^:]+):\s*(.*?)\s*$", line)
        if not match:
            continue

        raw_name = match.group(1).strip()
        raw_value = match.group(2).strip()
        optional = raw_name.startswith("~")
        name = raw_name.lstrip("~")
        content_type = None

        content_type_match = re.search(r"\s+@contentType\(([^)]+)\)\s*$", raw_value)
        if content_type_match:
            content_type = content_type_match.group(1)
            raw_value = raw_value[: content_type_match.start()].strip()

        file_match = re.match(r"^@file\(([^)]+)\)$", raw_value)
        if file_match:
            file_path = file_match.group(1)
            fields.append(
                {
                    "name": name,
                    "kind": "file",
                    "fileName": Path(file_path).name or "bruno-file",
                    "contentType": content_type or "application/octet-stream",
                    "optional": optional,
                }
            )
            continue

        fields.append(
            {
                "name": name,
                "kind": "value",
                "value": raw_value,
                "contentType": content_type,
                "optional": optional,
            }
        )

    return fields


def parse_request(path, collection_dir):
    """Parse one Bruno request file into the intermediate request model."""
    text = read_text(path)
    blocks = collect_blocks(text)
    method = next((name for name in HTTP_METHODS if name in blocks), None)
    if method is None:
        return None

    request_fields = parse_fields(blocks[method][0])
    raw_url = request_fields.get("url", "")
    if not raw_url:
        return None

    body_type = request_fields.get("body", "none")
    body = {"type": body_type}
    if body_type == "json" and "body:json" in blocks:
        body["raw"] = clean_body_json(blocks["body:json"][0])
    elif body_type == "multipartForm" and "body:multipart-form" in blocks:
        body["fields"] = parse_multipart(blocks["body:multipart-form"][0])

    meta = parse_meta(blocks)
    relative_path = path.relative_to(collection_dir).as_posix()
    display_name = meta["name"] or Path(relative_path).stem
    url_without_base = re.sub(r"^\{\{URL\}\}", "", raw_url)
    url_without_query = url_without_base.split("?", 1)[0]

    return {
        "name": f"{method.upper()} {url_without_query}",
        "displayName": display_name,
        "relativePath": relative_path,
        "method": method.upper(),
        "url": raw_url,
        "auth": request_fields.get("auth", "inherit"),
        "body": body,
        "vars": parse_vars(blocks),
        "seq": meta["seq"],
    }


def order_key(request):
    """Sort auth-ending requests after regular requests and login first."""
    url = request["url"]
    if LOGIN_PATH in url:
        return (0, request["relativePath"], request["seq"])
    if any(path in url for path in TOKEN_ENDING_PATHS):
        return (2, request["relativePath"], request["seq"])
    return (1, request["relativePath"], request["seq"])


def load_requests(collection_dir, include_external, include_destructive):
    """Load and filter HTTP requests from a Bruno collection directory."""
    requests = []
    for path in sorted(collection_dir.rglob("*.bru")):
        if path.name in ("collection.bru", "folder.bru"):
            continue
        if "environments" in path.relative_to(collection_dir).parts:
            continue

        request = parse_request(path, collection_dir)
        if request is None:
            continue
        if not include_external and not request["url"].startswith("{{URL}}"):
            continue
        if not include_destructive and any(path in request["url"] for path in DESTRUCTIVE_PATHS):
            continue
        requests.append(request)

    requests.sort(key=order_key)
    return requests


def render_k6(requests):
    """Render parsed Bruno requests as a self-contained k6 JavaScript file."""
    regular_requests = [request for request in requests if LOGIN_PATH not in request["url"]]
    payload = json.dumps(regular_requests, ensure_ascii=True, indent=2)

    return f"""import http from 'k6/http';
import {{ sleep, check }} from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://api.stage.solid-connection.com';
const testId = 'bruno-all-apis';
const requestSleepSeconds = Number(__ENV.BRUNO_REQUEST_SLEEP_SECONDS || '0.1');
const failOn5xx = (__ENV.BRUNO_FAIL_ON_5XX || 'true') !== 'false';
const loginEmailTemplate = __ENV.BRUNO_LOGIN_EMAIL_TEMPLATE || 'user{{{{VU}}}}@example.com';
const loginPassword = __ENV.BRUNO_LOGIN_PASSWORD || 'password';
const preloadedAccessToken = __ENV.BRUNO_ACCESS_TOKEN || '';

const now = new Date();
const kst = new Date(now.getTime() + 9 * 60 * 60 * 1000).toISOString().slice(0, 16);
const time = (() => {{
  const [, mm, dd, hh, min] = kst.split(/[-T:]/);
  return `${{mm}}/${{dd}} ${{hh}}:${{min}}`;
}})();

export const options = {{
  scenarios: {{
    bruno_all_apis: {{
      executor: 'per-vu-iterations',
      vus: Number(__ENV.K6_VUS || 10),
      iterations: Number(__ENV.K6_ITERATIONS || 10),
      maxDuration: __ENV.K6_MAX_DURATION || '15m',
    }},
  }},
  tags: {{
    testid: testId,
    time,
  }},
}};

const requests = {payload};

function envNameFor(variableName) {{
  return `BRUNO_VAR_${{variableName.toUpperCase().replace(/[^A-Z0-9]/g, '_')}}`;
}}

function fallbackValue(variableName) {{
  const explicit = __ENV[envNameFor(variableName)];
  if (explicit !== undefined) {{
    return explicit;
  }}

  const defaults = {{
    URL: BASE_URL,
    ACCESS_TOKEN: preloadedAccessToken,
    value: '1',
    id: '1',
    'home-university-id': '1',
    'term-id': '1',
    'board-code': 'FREE',
  }};
  return defaults[variableName] !== undefined ? defaults[variableName] : '1';
}}

function renderTemplate(value, variables) {{
  if (value === null || value === undefined) {{
    return value;
  }}
  return String(value).replace(/\\{{\\{{\\s*([^}}]+?)\\s*\\}}\\}}/g, (_, variableName) => {{
    const key = variableName.trim();
    return variables[key] !== undefined ? variables[key] : fallbackValue(key);
  }});
}}

function buildVariables(request, accessToken) {{
  return {{
    ...request.vars,
    URL: BASE_URL,
    ACCESS_TOKEN: accessToken || preloadedAccessToken,
  }};
}}

function resolveUrl(request, variables) {{
  const rendered = renderTemplate(request.url, variables);
  if (rendered.startsWith('http://') || rendered.startsWith('https://')) {{
    return rendered;
  }}
  return `${{BASE_URL}}${{rendered.startsWith('/') ? '' : '/'}}${{rendered}}`;
}}

function resolveLoginEmail() {{
  return loginEmailTemplate
    .replaceAll('{{{{VU}}}}', String(__VU))
    .replaceAll('${{__VU}}', String(__VU));
}}

function readAccessToken(response) {{
  try {{
    return response.json('accessToken') || '';
  }} catch (error) {{
    return '';
  }}
}}

function login() {{
  if (preloadedAccessToken) {{
    return preloadedAccessToken;
  }}

  const response = http.post(`${{BASE_URL}}{LOGIN_PATH}`, JSON.stringify({{
    email: resolveLoginEmail(),
    password: loginPassword,
  }}), {{
    headers: {{ 'Content-Type': 'application/json; charset=utf-8' }},
    tags: {{ ...options.tags, name: '{LOGIN_PATH}', brunoPath: 'generated-login' }},
  }});

  check(response, {{
    'generated login status is 200': (res) => res.status === 200,
    'generated login has access token': (res) => Boolean(readAccessToken(res)),
  }});

  return readAccessToken(response);
}}

function buildBody(request, variables) {{
  if (request.body.type === 'none') {{
    return null;
  }}
  if (request.body.type === 'json') {{
    return renderTemplate(request.body.raw || '{{}}', variables);
  }}
  if (request.body.type === 'multipartForm') {{
    const form = {{}};
    for (const field of request.body.fields || []) {{
      if (field.kind === 'file') {{
        form[field.name] = http.file('bruno-placeholder-file', field.fileName, field.contentType);
      }} else {{
        form[field.name] = renderTemplate(field.value || '', variables);
      }}
    }}
    return form;
  }}
  return null;
}}

function buildParams(request, variables) {{
  const headers = {{}};
  if (request.auth !== 'none') {{
    const accessToken = variables.ACCESS_TOKEN || preloadedAccessToken;
    if (accessToken) {{
      headers.Authorization = `Bearer ${{accessToken}}`;
    }}
  }}
  if (request.body.type === 'json') {{
    headers['Content-Type'] = 'application/json; charset=utf-8';
  }}
  return {{
    headers,
    tags: {{
      ...options.tags,
      name: request.name,
      method: request.method,
      brunoPath: request.relativePath,
      brunoName: request.displayName,
    }},
  }};
}}

export default function () {{
  const accessToken = login();

  for (const request of requests) {{
    const variables = buildVariables(request, accessToken);
    const url = resolveUrl(request, variables);
    const params = buildParams(request, variables);
    const body = buildBody(request, variables);

    let response;
    try {{
      response = http.request(request.method, url, body, params);
    }} catch (error) {{
      console.error(`Bruno request failed before response: ${{request.method}} ${{url}} ${{error.message}}`);
      continue;
    }}

    check(response, {{
      'bruno request did not return 5xx': (res) => !failOn5xx || res.status < 500,
    }});

    if (response.status >= 500) {{
      console.error(`Bruno request returned ${{response.status}}: ${{request.method}} ${{url}}`);
    }}

    if (requestSleepSeconds > 0) {{
      sleep(requestSleepSeconds);
    }}
  }}
}}
"""


def main():
    """Parse CLI arguments and write the generated k6 script."""
    parser = argparse.ArgumentParser(description="Generate a k6 script from a Bruno collection.")
    parser.add_argument("--collection-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--include-external",
        action="store_true",
        help="Include Bruno requests whose URL is not based on {{URL}}.",
    )
    parser.add_argument(
        "--include-destructive",
        action="store_true",
        help="Include destructive requests that can break repeated load-test iterations.",
    )
    args = parser.parse_args()

    collection_dir = args.collection_dir.resolve()
    if not collection_dir.exists():
        raise SystemExit(f"Bruno collection directory does not exist: {collection_dir}")

    requests = load_requests(collection_dir, args.include_external, args.include_destructive)
    if not requests:
        raise SystemExit(f"No Bruno HTTP requests found under: {collection_dir}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render_k6(requests), encoding="utf-8")
    print(f"Generated {args.output} from {len(requests)} Bruno HTTP requests.")


if __name__ == "__main__":
    main()
