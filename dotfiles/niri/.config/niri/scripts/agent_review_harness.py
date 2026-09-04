from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path


NIX_PACKAGES = {"git-lfs": "nixpkgs#git-lfs", "wt": "nixpkgs#worktrunk"}
SYSTEM_PATH = ("/run/current-system/sw/bin", "/usr/bin", "/bin")
PHASE_ONE_READINESS_TIMEOUT_MS = 300_000
BROWSER_READINESS_TIMEOUT_MS = 180_000
FULL_READINESS_TIMEOUT_SECONDS = 500


def run(args: list[str], *, cwd: Path | None = None, timeout: int = 30, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=check)


def valid_executable(path: Path, version_arg: str = "--version") -> bool:
    if not path.is_file() or not os.access(path, os.X_OK):
        return False
    try:
        return run([str(path), version_arg], timeout=5, check=False).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def deterministic_path(home: Path, cache_root: Path | None = None) -> dict[str, Path]:
    cache_root = cache_root or Path(os.environ.get("XDG_CACHE_HOME", home / ".cache")) / "agent-review/tools"
    resolved: dict[str, Path] = {}
    search = [home / ".nix-profile/bin", home / ".local/bin", *(Path(p) for p in SYSTEM_PATH)]
    for name, installable in NIX_PACKAGES.items():
        candidates = [directory / name for directory in search]
        marker = cache_root / name
        try:
            candidates.insert(0, Path(marker.read_text().strip()))
        except OSError:
            pass
        executable = next((p for p in candidates if valid_executable(p, "version" if name == "git-lfs" else "--version")), None)
        if executable is None:
            result = run(
                ["/run/current-system/sw/bin/nix", "build", "--no-link", "--print-out-paths", installable],
                timeout=60,
                check=False,
            )
            outputs = result.stdout.splitlines()
            executable = Path(outputs[-1]) / "bin" / name if result.returncode == 0 and outputs else Path()
            if not valid_executable(executable, "version" if name == "git-lfs" else "--version"):
                raise RuntimeError(f"could not provision {name}: {result.stderr.strip() or 'invalid Nix output'}")
            marker.parent.mkdir(parents=True, exist_ok=True)
            temporary = marker.with_suffix(".tmp")
            temporary.write_text(f"{executable}\n")
            temporary.replace(marker)
        resolved[name] = executable.resolve()
    ordered = list(dict.fromkeys([str(p.parent) for p in resolved.values()] + [str(p) for p in search]))
    os.environ["PATH"] = os.pathsep.join(ordered)
    return resolved


def git(args: list[str], cwd: Path, timeout: int = 30) -> str:
    return run(["git", "-C", str(cwd), *args], timeout=timeout).stdout.strip()


def worktree_records(repo: Path) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in git(["worktree", "list", "--porcelain"], repo).splitlines() + [""]:
        if not line:
            if current:
                records.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    return records


def require_clean_ancestor(worktree: Path, expected_sha: str) -> str:
    if git(["status", "--porcelain=v1"], worktree):
        raise RuntimeError(f"existing review worktree is dirty: {worktree}")
    actual = git(["rev-parse", "HEAD"], worktree)
    if actual != expected_sha:
        ancestor = run(
            ["git", "-C", str(worktree), "merge-base", "--is-ancestor", actual, expected_sha],
            check=False,
        )
        if ancestor.returncode:
            raise RuntimeError(f"existing review worktree HEAD {actual} is not behind PR head {expected_sha}")
    return actual


def verify_review_worktree(worktree: Path, expected_sha: str) -> Path:
    if git(["rev-parse", "HEAD"], worktree) != expected_sha:
        raise RuntimeError("updated review worktree does not match PR head")
    lfs = run(["git", "-C", str(worktree), "lfs", "fsck"], timeout=120, check=False)
    if lfs.returncode:
        raise RuntimeError(f"existing review worktree failed Git LFS fsck: {lfs.stderr.strip()}")
    return worktree


def adopt_or_create_worktree(repo: Path, pr: int, expected_sha: str, wt: Path) -> Path:
    branch = f"review/pr-{pr}"
    branch_ref = f"refs/heads/{branch}"
    records = worktree_records(repo)
    matches = [Path(item["worktree"]) for item in records if item.get("branch") == branch_ref]
    if len(matches) > 1:
        raise RuntimeError(f"multiple worktrees own {branch_ref}")
    if matches:
        adopted = matches[0]
        actual = require_clean_ancestor(adopted, expected_sha)
        if actual != expected_sha:
            git(["reset", "--hard", expected_sha], adopted)
        return verify_review_worktree(adopted, expected_sha)
    target_record = next((item for item in records if Path(item["worktree"]) == wt), None)
    if wt.exists():
        try:
            require_clean_ancestor(wt, expected_sha)
            common_dir = Path(git(["rev-parse", "--path-format=absolute", "--git-common-dir"], wt))
        except subprocess.CalledProcessError as error:
            raise RuntimeError(f"existing review path cannot be safely adopted: {wt}") from error
        if common_dir.resolve() != (repo / ".git").resolve():
            raise RuntimeError(f"existing review path belongs to another repository: {wt}")
        branch_sha = run(["git", "-C", str(repo), "rev-parse", "--verify", branch_ref], check=False)
        if branch_sha.returncode == 0:
            branch_head = branch_sha.stdout.strip()
            if branch_head != expected_sha and run(
                ["git", "-C", str(repo), "merge-base", "--is-ancestor", branch_head, expected_sha], check=False,
            ).returncode:
                raise RuntimeError(f"existing review branch {branch_head} is not behind PR head {expected_sha}")
        git(["branch", "-f", branch, expected_sha], repo)
        if target_record is not None:
            git(["switch", branch], wt)
            return verify_review_worktree(wt, expected_sha)
        shutil.rmtree(wt)
    branch_exists = run(["git", "-C", str(repo), "show-ref", "--verify", "--quiet", branch_ref], check=False).returncode == 0
    command = ["wt", "switch", "-C", str(repo)]
    if branch_exists:
        command.append(branch)
    else:
        command.extend(["--create", branch, "--base", expected_sha])
    command.extend(["--no-hooks", "--yes", "--no-cd", "--format", "json"])
    result = run(command, timeout=120, check=False)
    if result.returncode:
        raise RuntimeError(f"Worktrunk could not create review worktree: {result.stderr.strip()}")
    matches = [Path(item["worktree"]) for item in worktree_records(repo) if item.get("branch") == branch_ref]
    if len(matches) != 1:
        raise RuntimeError(f"Worktrunk did not create exactly one {branch_ref} worktree")
    created = matches[0]
    if git(["rev-parse", "HEAD"], created) != expected_sha:
        raise RuntimeError("created review worktree does not match PR head")
    return created


@dataclass(frozen=True)
class HarnessPorts:
    browser: int
    browser_debug: int
    web_forward: int
    browser_api_forward: int
    compatibility_api_forward: int
    vm_web: int
    vm_api: int


@dataclass(frozen=True)
class HarnessContext:
    context_id: str
    pr: int
    expected_sha: str
    project_id: str
    worktree: str
    vm_host: str
    vm_user: str
    ports: HarnessPorts
    units: dict[str, str]
    remote_units: dict[str, str]
    readiness: str
    teardown: str
    runtime_contract: str = "production"
    enabled_at_boot: bool = False


class ManualHarness:
    def __init__(
        self,
        *,
        home: Path,
        pr: int,
        expected_sha: str,
        project_id: str,
        worktree: Path,
        ports: HarnessPorts,
        vm_host: str,
        vm_user: str,
        browser_profile_seed: Path | None = None,
        allow_sandbox_start: bool = False,
        runtime_contract: str = "production",
        state_home: Path | None = None,
    ) -> None:
        self.home = home
        self.context_id = f"pr-{pr}"
        self.root = (state_home or Path(os.environ.get("XDG_STATE_HOME", home / ".local/state"))) / "agent-review" / self.context_id
        self.pr = pr
        self.expected_sha = expected_sha
        self.project_id = project_id
        self.worktree = worktree
        self.ports = ports
        self.vm_host = vm_host
        self.vm_user = vm_user
        self.browser_profile_seed = browser_profile_seed
        self.allow_sandbox_start = allow_sandbox_start
        if runtime_contract not in {"production", "exact-branch"}:
            raise ValueError("runtime_contract must be production or exact-branch")
        self.runtime_contract = runtime_contract
        self.exact_runtime_override = runtime_contract == "exact-branch"
        self.units = {
            "connectivity": f"agent-review-{self.context_id}-connectivity.service",
            "keyless_proxy": f"agent-review-{self.context_id}-keyless-proxy.service",
            "browser": f"agent-review-{self.context_id}-browser.service",
        }
        self.remote_units = {"vm_slice": f"agent-review-{self.context_id}-vm.service"}
        if self.exact_runtime_override:
            self.units["runtime_https"] = f"agent-review-{self.context_id}-runtime-https.service"

    def context(self) -> HarnessContext:
        readiness = f"/bin/sh {self.root / 'readiness.sh'}"
        teardown = f"agent-review --teardown {self.context_id}"
        return HarnessContext(
            context_id=self.context_id,
            pr=self.pr,
            expected_sha=self.expected_sha,
            project_id=self.project_id,
            worktree=str(self.worktree),
            vm_host=self.vm_host,
            vm_user=self.vm_user,
            ports=self.ports,
            units=self.units,
            remote_units=self.remote_units,
            readiness=readiness,
            teardown=teardown,
            runtime_contract=self.runtime_contract,
        )

    def render_proxy(self) -> str:
        return f'''import http from "node:http";\nimport net from "node:net";\nconst listenPort={self.ports.browser};\nconst targetPort={self.ports.web_forward};\nconst modulePath="/modules/design-system/home/AuthoringCanvas.tsx";\nconst assignment=/const TLDRAW_LICENSE_KEY\\s*=\\s*"[^"]*";/g;\nconst agent=new http.Agent({{keepAlive:true}});\nconst server=http.createServer((req,res)=>{{\n const patch=new URL(req.url,"http://localhost").pathname===modulePath;\n const headers={{...req.headers}}; if(patch) headers["accept-encoding"]="identity";\n const upstream=http.request({{hostname:"127.0.0.1",port:targetPort,method:req.method,path:req.url,headers,agent}},upstreamRes=>{{\n  if(!patch){{res.writeHead(upstreamRes.statusCode??502,upstreamRes.headers);upstreamRes.pipe(res);return;}}\n  const chunks=[];upstreamRes.on("data",chunk=>chunks.push(chunk));upstreamRes.on("end",()=>{{\n   const source=Buffer.concat(chunks).toString("utf8");const matches=source.match(assignment)??[];\n   if(matches.length!==1){{res.writeHead(502,{{"content-type":"text/plain"}});res.end(`Expected one TLDRAW_LICENSE_KEY assignment, found ${{matches.length}}`);return;}}\n   const body=source.replace(assignment,'const TLDRAW_LICENSE_KEY = "";');const out={{...upstreamRes.headers,"content-length":Buffer.byteLength(body),"cache-control":"no-store"}};\n   delete out["content-encoding"];delete out["transfer-encoding"];delete out.etag;res.writeHead(upstreamRes.statusCode??200,out);res.end(body);\n  }});\n }});upstream.on("error",error=>{{if(!res.headersSent)res.writeHead(502,{{"content-type":"text/plain"}});res.end(error.message);}});req.pipe(upstream);\n}});\nserver.on("upgrade",(req,socket,head)=>{{const upstream=net.connect(targetPort,"127.0.0.1",()=>{{const lines=[`${{req.method}} ${{req.url}} HTTP/${{req.httpVersion}}`];for(const [name,value] of Object.entries(req.headers)){{if(Array.isArray(value))for(const item of value)lines.push(`${{name}}: ${{item}}`);else if(value!==undefined)lines.push(`${{name}}: ${{value}}`);}}upstream.write(`${{lines.join("\\r\\n")}}\\r\\n\\r\\n`);if(head.length)upstream.write(head);socket.pipe(upstream).pipe(socket);}});upstream.on("error",()=>socket.destroy());socket.on("error",()=>upstream.destroy());}});\nserver.keepAliveTimeout=65000;server.headersTimeout=66000;server.listen(listenPort,"127.0.0.1");\n'''

    def render_readiness(self) -> str:
        p = self.ports
        return f'''import crypto from "node:crypto";\nimport net from "node:net";\nimport {{execFile}} from "node:child_process";\nimport {{promisify}} from "node:util";\nconst exec=promisify(execFile), expectedSha={json.dumps(self.expected_sha)}, worktree={json.dumps(str(self.worktree))};\nconst deadline=Date.now()+{PHASE_ONE_READINESS_TIMEOUT_MS},sleep=ms=>new Promise(r=>setTimeout(r,ms));\nasync function fetchText(url,status=200){{const r=await fetch(url,{{signal:AbortSignal.timeout(5000)}}),b=await r.text();if(r.status!==status)throw Error(`${{url}} returned ${{r.status}}, expected ${{status}}`);return b;}}\nasync function hmr(token){{return new Promise((ok,no)=>{{const s=net.connect({p.browser},"127.0.0.1"),t=setTimeout(()=>s.destroy(Error("HMR timeout")),5000);let out="";s.on("connect",()=>s.write([`GET /?token=${{token}} HTTP/1.1`,`Host: localhost:{p.browser}`,`Origin: http://localhost:{p.browser}`,"Upgrade: websocket","Connection: Upgrade",`Sec-WebSocket-Key: ${{crypto.randomBytes(16).toString("base64")}}`,`Sec-WebSocket-Version: 13`,`Sec-WebSocket-Protocol: vite-hmr`,"",""].join("\\r\\n")));s.on("data",c=>{{out+=c;if(!out.includes("\\r\\n\\r\\n"))return;clearTimeout(t);s.end();out.startsWith("HTTP/1.1 101")&&/Sec-WebSocket-Protocol: vite-hmr/i.test(out)?ok():no(Error(out.split("\\r\\n")[0]));}});s.on("error",no);}});}}\nlet last;while(Date.now()<deadline){{try{{\n const local=(await exec("/run/current-system/sw/bin/git",["-C",worktree,"rev-parse","HEAD"],{{timeout:5000}})).stdout.trim();if(local!==expectedSha)throw Error(`worktree SHA ${{local}} != ${{expectedSha}}`);\n const route=await fetchText("http://127.0.0.1:{p.browser}/server-entry.ts");if(!route.includes(`\"VITE_GIT_COMMIT_SHA\": \"${{expectedSha}}\"`))throw Error("served SHA mismatch");\n await exec("/run/current-system/sw/bin/systemctl",["--user","is-active","--quiet",{json.dumps(self.units['connectivity'])}],{{timeout:5000}});await exec("/run/current-system/sw/bin/systemctl",["--user","is-active","--quiet",{json.dumps(self.units['keyless_proxy'])}],{{timeout:5000}});await exec("/run/current-system/sw/bin/systemctl",["--user","is-active","--quiet",{json.dumps(self.units['browser'])}],{{timeout:5000}});\n await exec("/run/current-system/sw/bin/ssh",["-o","BatchMode=yes",{json.dumps(f'{self.vm_user}@{self.vm_host}')},`bash "$HOME/.local/state/agent-review/{self.context_id}/readiness.sh" ${{expectedSha}}`],{{timeout:10000}});\n const vite=await fetchText("http://127.0.0.1:{p.browser}/@vite/client");const m=vite.match(/const wsToken = "([^"]+)"/);if(!m)throw Error("missing HMR token");await hmr(m[1]);\n await fetchText("http://127.0.0.1:{p.browser_api_forward}/health");await fetchText("http://127.0.0.1:{p.compatibility_api_forward}/health");\n const gate=await fetchText("http://127.0.0.1:{p.browser_api_forward}/v1/projects/{self.project_id}",401);if(!gate.includes("Authorization header required"))throw Error("browser API did not reach auth gate");\n console.log(`ready sha=${{expectedSha}} services=active tunnels=ready vite-hmr=101 api=ready`);process.exit(0);\n}}catch(e){{last=e;await sleep(500);}}}}throw Error(`readiness deadline exceeded: ${{last?.message??"unknown"}}`);\n'''

    def render_browser_readiness(self) -> str:
        template = r'''import fs from "node:fs";
import crypto from "node:crypto";
const debugPort=__DEBUG__,projectId=__PROJECT__,browserUrl=__BROWSER_URL__,allowStart=__ALLOW__,expectedSha=__EXPECTED__,runtimeMode=__RUNTIME_MODE__;
const root=__ROOT__,certification=`${root}/browser-certification.json`,startStateFile=`${root}/sandbox-start-state.json`,recoveryFile=`${root}/connectivity-recovery.json`,deadline=Date.now()+__BROWSER_TIMEOUT__;
let startState=fs.existsSync(startStateFile)?JSON.parse(fs.readFileSync(startStateFile,"utf8")):{requestCount:0,status:"unused"};
if(!Number.isInteger(startState.requestCount)||startState.requestCount<0)throw Error("invalid sandbox-start request accounting");
const persistStartState=(status,extra={})=>{startState={...startState,status,...extra,updatedAt:new Date().toISOString()};fs.writeFileSync(startStateFile,JSON.stringify(startState,null,2)+"\n");};
const connectivityRecovery=fs.existsSync(recoveryFile)?JSON.parse(fs.readFileSync(recoveryFile,"utf8")):null;
const runtimeOverrideFile=`${root}/runtime-override.json`,runtimeOverride=fs.existsSync(runtimeOverrideFile)?JSON.parse(fs.readFileSync(runtimeOverrideFile,"utf8")):null;
if(!["production","exact-branch"].includes(runtimeMode))throw Error("runtime contract mode is missing or invalid");
if(runtimeMode==="exact-branch"&&(!runtimeOverride?.url||!/^https:\/\//.test(runtimeOverride.url)||!/^[0-9a-f]{64}$/.test(runtimeOverride.contentDigest??"")||runtimeOverride.fingerprint!==`sha256:${runtimeOverride.contentDigest}`||!runtimeOverride.scriptVersion))throw Error("exact-branch runtime contract URL/content digest/fingerprint/script version is missing or invalid");
if(runtimeMode==="exact-branch"&&runtimeOverride.expectedSha!==expectedSha)throw Error("exact-branch runtime contract head identity mismatch");
if(runtimeMode==="production"&&runtimeOverride)throw Error("production runtime contract must not load an override artifact");
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function targets(){const response=await fetch(`http://127.0.0.1:${debugPort}/json/list`,{signal:AbortSignal.timeout(3000)});if(!response.ok)throw Error(`CDP target list returned ${response.status}`);return response.json();}
class CDP{constructor(url){this.url=url;this.id=0;this.pending=new Map();this.events=[];}async open(){this.ws=new WebSocket(this.url);await new Promise((ok,no)=>{this.ws.onopen=ok;this.ws.onerror=no;});this.ws.onmessage=event=>{const message=JSON.parse(event.data);if(message.id&&this.pending.has(message.id)){const pending=this.pending.get(message.id);this.pending.delete(message.id);message.error?pending.no(Error(JSON.stringify(message.error))):pending.ok(message.result);return;}this.events.push(message);};}send(method,params={}){return new Promise((ok,no)=>{const id=++this.id;this.pending.set(id,{ok,no});this.ws.send(JSON.stringify({id,method,params}));setTimeout(()=>{if(this.pending.delete(id))no(Error(`${method} timed out`));},5000);});}async evaluate(expression){const result=await this.send("Runtime.evaluate",{expression,awaitPromise:true,returnByValue:true});if(result.exceptionDetails)throw Error(result.exceptionDetails.exception?.description??result.exceptionDetails.text);return result.result.value;}close(){this.ws?.close();}}
function digest(value){return crypto.createHash("sha256").update(value).digest("hex");}
async function pinRuntime(client){if(runtimeMode!=="exact-branch")return;await client.send("Fetch.enable",{patterns:[{urlPattern:"*",resourceType:"Document",requestStage:"Response"}]});try{await client.evaluate("location.reload()");}catch{}let patched=false;while(Date.now()<deadline&&!patched){for(const event of client.events.splice(0)){if(event.method!=="Fetch.requestPaused")continue;const body=await client.send("Fetch.getResponseBody",{requestId:event.params.requestId});const source=body.base64Encoded?Buffer.from(body.body,"base64").toString("utf8"):body.body;const selector="https://cdn.gpteng.co/lovable.js";const count=source.split(selector).length-1;if(count!==1){await client.send("Fetch.failRequest",{requestId:event.params.requestId,errorReason:"BlockedByClient"});throw Error(`expected one production runtime selector, found ${count}`);}const replaced=source.replace(selector,runtimeOverride.url);await client.send("Fetch.fulfillRequest",{requestId:event.params.requestId,responseCode:event.params.responseStatusCode??200,responseHeaders:(event.params.responseHeaders??[]).filter(header=>!['content-length','content-encoding'].includes(header.name.toLowerCase())),body:Buffer.from(replaced).toString("base64")});patched=true;}if(!patched)await sleep(50);}await client.send("Fetch.disable");if(!patched)throw Error("isolated project runtime selector override timed out");}
const isProjectHost=host=>host===`${projectId}.lovableproject-dev.com`||host===`id-preview--${projectId}.gpt-eng.com`;
const targetUrl=target=>{try{return new URL(target.url)}catch{return null;}};
const isSelectedLive=target=>{const url=targetUrl(target);return target.type==="iframe"&&url?.pathname==="/"&&isProjectHost(url.hostname);};
let list=await targets(),live=list.find(isSelectedLive);
let page=list.find(target=>target.type==="page"&&target.url.includes(`/projects/${projectId}`))||list.find(target=>target.type==="page");
if(!page)throw Error("isolated browser page target missing");
if(allowStart&&startState.requestCount>0)throw Error("sandbox-start POST was already issued; refusing a retry");
const snapshotExpression=`(()=>{const target=document.querySelector("button")??document.body?.firstElementChild??document.body;if(!target)return "";window.__agentReviewDocumentId??=crypto.randomUUID();const style=getComputedStyle(target);return JSON.stringify({documentId:window.__agentReviewDocumentId,html:target.outerHTML,style:{backgroundColor:style.backgroundColor,color:style.color,cursor:style.cursor,display:style.display,opacity:style.opacity,padding:style.padding,pointerEvents:style.pointerEvents}})})()`;
let parent=null,frame=null,specimen=null,liveId=null,specimenId=null,before=null,after=null,restored=null,result=null,failure=null,mutationSent=false,typedControls=null,navigationTimedOut=false,fixtureSnapshot=null,branchRuntimeUrl=null,apiAuthorization=null,navigationAttempts=0,navigationStartedAt=0,recoveryNavigated=false,failedModuleUrls=new Set(),targetRecovery=null;
const configureParent=async target=>{const client=new CDP(target.webSocketDebuggerUrl);await client.open();try{await client.send("Network.enable");await client.send("Runtime.enable");await client.send("Page.enable");await client.send("Fetch.enable",{patterns:[{urlPattern:"*sandbox/start*",requestStage:"Request"}]});return client;}catch(error){client.close();throw error;}};
try{
 try{parent=await configureParent(page);}catch(error){const unused=startState.requestCount===0&&startState.status==="unused",consumedAttach=startState.requestCount===1&&startState.status==="succeeded"&&!allowStart;if((!unused&&!consumedAttach)||!error.message.endsWith(" timed out"))throw error;const version=await fetch(`http://127.0.0.1:${debugPort}/json/version`,{signal:AbortSignal.timeout(3000)}).then(response=>response.json());const browser=new CDP(version.webSocketDebuggerUrl);await browser.open();let replacement;try{replacement=await browser.send("Target.createTarget",{url:"about:blank"});await browser.send("Target.closeTarget",{targetId:page.id});}catch(recoveryError){if(replacement?.targetId)try{await browser.send("Target.closeTarget",{targetId:replacement.targetId});}catch{}throw recoveryError;}finally{browser.close();}list=await targets();page=list.find(target=>target.id===replacement.targetId&&target.type==="page");if(!page)throw Error("replacement isolated browser page target missing");live=null;targetRecovery={reason:error.message,replacedTargetId:replacement.targetId};parent=await configureParent(page);}
 const capture=`window.__agentReviewMessages=[];window.addEventListener("message",event=>{if(event.data?.type==="CONNECTION_HELLO"){const frame=[...document.querySelectorAll("iframe")].find(node=>node.contentWindow===event.source);window.__agentReviewMessages.push({message:event.data,origin:event.origin,sourceUrl:frame?.src??null,transport:"window.postMessage"})}})`;
 await parent.send("Page.addScriptToEvaluateOnNewDocument",{source:capture});await parent.evaluate(capture);
 const browserOrigin=new URL(browserUrl).origin;
 const navigate=async()=>{navigationAttempts++;navigationStartedAt=Date.now();failedModuleUrls.clear();try{await parent.send("Page.navigate",{url:`${browserUrl}&agent_review_certification=${Date.now()}`});}catch(error){if(error.message!=="Page.navigate timed out")throw error;navigationTimedOut=true;}};
 await navigate();
 let hydrated=false,apiStatus=null,startRequest=null,startResponse=null,blockedStarts=0,blockedDuplicateStarts=0,replayedStarts=0,requestMethods=new Map(),requestAuthorizations=new Map(),projectStatuses=new Map();
 while(Date.now()<deadline){
  for(const event of parent.events.splice(0)){if(event.method==="Fetch.requestPaused"){const request=event.params.request,isSandboxStart=request.method==="POST"&&request.url.includes("/sandbox/start");if(isSandboxStart&&!allowStart){const authorization=request.headers?.Authorization??request.headers?.authorization;if(authorization){const discovery=await fetch(`http://127.0.0.1:__API_PORT__/projects/${projectId}/sandbox/url`,{headers:{Authorization:authorization},signal:AbortSignal.timeout(5000)});const discovered=discovery.ok?await discovery.json():null;const host=discovered?.url?new URL(discovered.url).hostname:"";if(isProjectHost(host)){apiAuthorization=authorization;apiStatus=discovery.status;replayedStarts++;await parent.send("Fetch.fulfillRequest",{requestId:event.params.requestId,responseCode:200,responseHeaders:[{name:"content-type",value:"application/json"}],body:Buffer.from(JSON.stringify(discovered)).toString("base64")});}else{blockedStarts++;await parent.send("Fetch.failRequest",{requestId:event.params.requestId,errorReason:"BlockedByClient"});}}else{blockedStarts++;await parent.send("Fetch.failRequest",{requestId:event.params.requestId,errorReason:"BlockedByClient"});}}else if(isSandboxStart){if(startRequest){blockedDuplicateStarts++;await parent.send("Fetch.failRequest",{requestId:event.params.requestId,errorReason:"BlockedByClient"});}else{const authorization=request.headers?.Authorization??request.headers?.authorization;if(!authorization){await parent.send("Fetch.failRequest",{requestId:event.params.requestId,errorReason:"BlockedByClient"});throw Error("sandbox-start request lacked authorization for preflight proof");}const preflight=await fetch(`http://127.0.0.1:__API_PORT__/projects/${projectId}/sandbox/url`,{headers:{Authorization:authorization},signal:AbortSignal.timeout(5000)});const preflightBody=preflight.ok?await preflight.json():null;let preflightHost="";try{preflightHost=preflightBody?.url?new URL(preflightBody.url).hostname:""}catch{}if(!preflight.ok||!isProjectHost(preflightHost)){await parent.send("Fetch.failRequest",{requestId:event.params.requestId,errorReason:"BlockedByClient"});throw Error(`authenticated sandbox URL preflight returned ${preflight.status} or an untrusted host`);}apiAuthorization=authorization;apiStatus=preflight.status;startRequest={fetchRequestId:event.params.requestId,method:request.method,url:request.url,observedAt:new Date().toISOString()};await parent.send("Fetch.continueRequest",{requestId:event.params.requestId});startState.requestCount++;persistStartState("issued",{request:startRequest});}}else await parent.send("Fetch.continueRequest",{requestId:event.params.requestId});}if(event.method==="Network.requestWillBeSent"){requestMethods.set(event.params.requestId,event.params.request.method);const authorization=event.params.request.headers?.Authorization??event.params.request.headers?.authorization;if(authorization)requestAuthorizations.set(event.params.requestId,authorization);if(startRequest&&!startRequest.networkRequestId&&event.params.request.method==="POST"&&event.params.request.url.includes("/sandbox/start"))startRequest.networkRequestId=event.params.requestId;}if(event.method==="Network.requestWillBeSentExtraInfo"){const authorization=event.params.headers?.Authorization??event.params.headers?.authorization;if(authorization){requestAuthorizations.set(event.params.requestId,authorization);const status=projectStatuses.get(event.params.requestId);if(status){apiAuthorization=authorization;apiStatus=status;}}}if(event.method==="Network.responseReceived"){const response=event.params.response,parsed=new URL(response.url);if(response.status>=500&&parsed.origin===browserOrigin)failedModuleUrls.add(response.url);if(requestMethods.get(event.params.requestId)==="GET"&&(parsed.pathname===`/projects/${projectId}`||parsed.pathname.startsWith(`/projects/${projectId}/`))&&[String(__API_PORT__),String(__COMPAT_PORT__)].includes(parsed.port)&&response.status>=200&&response.status<300){projectStatuses.set(event.params.requestId,response.status);apiStatus=response.status;apiAuthorization=requestAuthorizations.get(event.params.requestId)??apiAuthorization;}if(!startResponse&&response.url.includes(`/projects/${projectId}/sandbox/start`)&&requestMethods.get(event.params.requestId)==="POST"){startResponse={status:response.status,requestId:event.params.requestId,observedAt:new Date().toISOString()};persistStartState(response.status===200?"succeeded":"failed",{response:startResponse});}}}
  try{hydrated=await parent.evaluate(`Boolean(document.querySelector('#preview-panel'))&&document.body.innerText.length>0`);}catch{}
  list=await targets();live=list.find(isSelectedLive);
  if(!hydrated&&!live&&!startRequest&&!recoveryNavigated&&failedModuleUrls.size&&Date.now()-navigationStartedAt>=10000){let recovered=true;for(const url of failedModuleUrls){try{const response=await fetch(url,{signal:AbortSignal.timeout(5000)});if(!response.ok){recovered=false;break;}}catch{recovered=false;break;}}if(recovered){recoveryNavigated=true;apiStatus=null;apiAuthorization=null;await navigate();}}
  if(hydrated&&apiStatus&&apiAuthorization&&live)break;await sleep(250);
 }
 const readyPage=list.find(target=>target.id===page.id&&target.type==="page");
 let readyPageUrl=null;try{readyPageUrl=new URL(await parent.evaluate("location.href"));}catch{}
 if(!hydrated||!readyPageUrl||readyPageUrl.pathname!==`/projects/${projectId}`)throw Error(`authenticated exact-project UI did not hydrate within __BROWSER_TIMEOUT_SECONDS__s after ${navigationAttempts} bounded navigation attempt(s)`);
 if(navigationTimedOut&&!live)throw Error("Page.navigate timed out without bounded exact-app/live-iframe readiness proof");
 if(blockedDuplicateStarts)throw Error(`blocked ${blockedDuplicateStarts} duplicate sandbox-start attempt(s)`);
 if(blockedStarts)throw Error("page attempted sandbox-start without bounded approval");
 if(!apiStatus||!apiAuthorization)throw Error("fresh authenticated project API success was not observed");
 if(startRequest&&!startResponse)throw Error("sandbox-start request completed without an observed response");
 if(startResponse&&startResponse.status!==200)throw Error(`sandbox-start returned ${startResponse.status}`);
 if(replayedStarts>1)throw Error(`replayed ${replayedStarts} existing-sandbox attachments`);
 if(!live)throw Error("selected lovableproject-dev iframe missing");
 liveId=live.id;frame=new CDP(live.webSocketDebuggerUrl);await frame.open();await frame.send("Runtime.enable");await pinRuntime(frame);
 branchRuntimeUrl=await frame.evaluate(`([...document.scripts].map(node=>node.src).find(src=>src.includes('lovable.js'))??performance.getEntriesByType('resource').map(entry=>entry.name).find(url=>url.includes('lovable.js'))??null)`);
 if(!branchRuntimeUrl)throw Error("live sandbox runtime source URL is missing");
 if(runtimeMode==="exact-branch"&&new URL(branchRuntimeUrl).hostname==="cdn.gpteng.co")throw Error("mixed production CDN runtime with exact-branch parent");
 if(runtimeMode==="exact-branch"&&branchRuntimeUrl!==runtimeOverride.url)throw Error("live sandbox did not load the exact-branch runtime contract URL");
 if(runtimeMode==="production"&&new URL(branchRuntimeUrl).hostname!=="cdn.gpteng.co")throw Error("production runtime contract did not load the production CDN runtime");
 let fixtureError=null;while(Date.now()<deadline&&!fixtureSnapshot){try{fixtureSnapshot=await parent.evaluate(`(()=>{if(!document.querySelector('#preview-panel'))throw Error('preview panel missing');const host=document.querySelector('.tl-container')??document.querySelector('#root'),key=Object.keys(host??{}).find(name=>name.startsWith('__reactFiber$'));let fiber=host?.[key];while(fiber?.return)fiber=fiber.return;const queue=[fiber];let editor=null;while(queue.length&&!editor){const node=queue.shift();if(!node)continue;let context=node.dependencies?.firstContext;while(context){const value=context.memoizedValue;if(value&&typeof value.getShape==='function'&&typeof value.select==='function'){editor=value;break}context=context.next}queue.push(node.child,node.sibling)}if(!editor)throw Error('tldraw editor missing');window.__agentReviewEditor=editor;const canonical=editor.getShape('shape:component-anchor-Button');const candidates=editor.getCurrentPageShapes().filter(shape=>shape.id!==canonical?.id&&(String(shape.id).includes('candidate')||String(shape.props?.src??shape.props?.path??shape.meta?.sourcePath??'').includes('-candidate-')));return {pageId:editor.getCurrentPageId(),selectedShapeIds:editor.getSelectedShapeIds(),canonicalShape:canonical?{id:canonical.id,props:structuredClone(canonical.props)}:null,specimenProps:structuredClone(canonical?.props?.specimenProps??{}),candidateIds:candidates.map(shape=>shape.id),candidateFiles:candidates.map(shape=>shape.props?.src??shape.props?.path??shape.meta?.sourcePath).filter(Boolean)}})()`);}catch(error){fixtureError=error;await sleep(100);}}if(!fixtureSnapshot)throw fixtureError??Error("tldraw fixture snapshot timed out");
 let canonicalSelection=null,selectionError=null;while(Date.now()<deadline&&!canonicalSelection){try{canonicalSelection=await parent.evaluate(`(()=>{const editor=window.__agentReviewEditor;if(!editor)throw Error('tldraw editor missing');const shape=editor.getShape('shape:component-anchor-Button');if(!shape||shape.props?.kind!=='component'||shape.meta?.dsComponentKey!=='Button')throw Error('canonical Button shape missing');editor.select(shape.id);return {id:shape.id,kind:shape.props.kind,componentKey:shape.meta.dsComponentKey}})()`)}catch(error){selectionError=error;await sleep(100);}}if(!canonicalSelection)throw selectionError??Error("canonical Button selection timed out");
 while(Date.now()<deadline){typedControls=await parent.evaluate(`(()=>{const layout=document.querySelector('.tlui-layout'),portal=document.querySelector('[data-testid="specimen-controls-container"]');return {viewport:{width:innerWidth,height:innerHeight},breakpoint:Number(layout?.dataset.breakpoint??-1),text:portal?.innerText??'',htmlBytes:portal?.innerHTML.length??0}})()`);if(typedControls.breakpoint>=4&&typedControls.htmlBytes>0&&['Specimen','Reset','variant','primary','size','md'].every(value=>typedControls.text.includes(value)))break;await sleep(100);}
 if(typedControls?.viewport.width!==1920||typedControls.viewport.height<900)throw Error(`canonical browser viewport is ${typedControls?.viewport.width}x${typedControls?.viewport.height}, expected 1920x>=900`);
 if(typedControls.breakpoint<4||typedControls.htmlBytes===0)throw Error("canonical Button typed-controls portal missing at required tldraw breakpoint");
 await parent.evaluate(`window.__agentReviewMessages=window.__agentReviewMessages??[]`);
 list=await targets();const specimenTarget=list.find(target=>{const url=targetUrl(target);return target.type==="iframe"&&url?.pathname.startsWith("/__component/preview/")&&isProjectHost(url.hostname);});if(!specimenTarget)throw Error("live specimen iframe target missing");
 specimenId=specimenTarget.id;specimen=new CDP(specimenTarget.webSocketDebuggerUrl);await specimen.open();await specimen.send("Network.enable");await specimen.send("Runtime.enable");
 await pinRuntime(specimen);if(runtimeMode==="production")await specimen.evaluate("location.reload()");
 let websocket=null,hello=null;
 while(Date.now()<deadline){
  for(const event of specimen.events.splice(0)){if(event.method==="Network.webSocketHandshakeResponseReceived"&&event.params.response.status===101&&String(event.params.response.headers?.["Sec-WebSocket-Protocol"]??event.params.response.headers?.["sec-websocket-protocol"]??"").includes("vite-hmr"))websocket={requestId:event.params.requestId,status:101};}
  try{hello=await parent.evaluate(`window.__agentReviewMessages.find(entry=>entry.message?.type==="CONNECTION_HELLO")??null`);}catch{}
  if(websocket&&hello)break;await sleep(100);
 }
 if(!websocket)throw Error("live iframe-owned Vite WebSocket was not connected");
 if(!hello?.message?.payload||typeof hello.message.payload.protocolVersion!=="number"||!hello.message.payload.sessionId||!Array.isArray(hello.message.payload.capabilities)||!hello.message.payload.scriptVersion||hello.transport!=="window.postMessage"||!hello.origin||!hello.sourceUrl)throw Error("CONNECTION_HELLO transport/runtime fingerprint is incomplete");
 const servedSource=await parent.evaluate(`fetch('/server-entry.ts',{cache:'no-store'}).then(response=>response.text())`);const servedSha=servedSource.match(/"VITE_GIT_COMMIT_SHA": "([0-9a-f]{40})"/)?.[1];if(servedSha!==expectedSha)throw Error(`served monorepo SHA ${servedSha??"missing"} != ${expectedSha}`);
 const runtimeSourceUrl=`http://127.0.0.1:__API_PORT__/v1/git/files/mockupPreviewPlugin.ts?project_id=${projectId}`;
 const runtimeSource=await parent.evaluate(`fetch(${JSON.stringify(runtimeSourceUrl)},{headers:{Authorization:${JSON.stringify(apiAuthorization)}}}).then(async response=>{if(!response.ok)throw Error('runtime source returned '+response.status);return response.text()})`);
 const runtimeVersion=runtimeSource.match(/LOVABLE_CANVAS_MOCKUP_PREVIEW_RUNTIME_VERSION\s*=\s*"([^"]+)"/)?.[1];
 const runtimeFingerprint=runtimeSource.match(/LOVABLE_CANVAS_MOCKUP_PREVIEW_RUNTIME_FINGERPRINT\s*=\s*"(sha256:[0-9a-f]{64})"/)?.[1];
 const runtimeCapabilities={specimenProps:runtimeSource.includes('message.type !== "DS_SPECIMEN_PROPS"'),parentSourceGuard:runtimeSource.includes('event.source !== parent'),componentPreview:runtimeSource.includes('createFileRoute("/__component/preview/$")'),mockupPreview:runtimeSource.includes('createFileRoute("/__mockup/preview/$")'),viteWatcher:runtimeSource.includes('server.watcher.on("add"')&&runtimeSource.includes('server.watcher.on("unlink"')};
 const runtimeContentDigest=digest(runtimeSource);
 if(runtimeVersion!=="2026-08-17.2"||runtimeFingerprint!=="sha256:d095fa605d961269d9e25b0f456da72cade838b64561af75f5c52c148e6a2430"||runtimeContentDigest!=="49fc9bddb4ff4d5cd63ba9af87f43c207e3659479360f23a3721f44bb85ae85f"||Object.values(runtimeCapabilities).some(value=>!value))throw Error("Canvas runtime authoritative fingerprint or handler completeness is invalid");
 const loadedRuntimeUrl=await specimen.evaluate(`([...document.scripts].map(node=>node.src).find(src=>src.includes('lovable.js'))??performance.getEntriesByType('resource').map(entry=>entry.name).find(url=>url.includes('lovable.js'))??null)`);
 if(!loadedRuntimeUrl)throw Error("live iframe runtime source URL is missing");
 if(runtimeMode==="exact-branch"&&new URL(loadedRuntimeUrl).hostname==="cdn.gpteng.co")throw Error("mixed production CDN runtime with exact-branch parent");
 if(loadedRuntimeUrl!==branchRuntimeUrl||runtimeMode==="exact-branch"&&loadedRuntimeUrl!==runtimeOverride.url)throw Error("live specimen did not load the contracted runtime URL");
 if(runtimeMode==="production"&&new URL(loadedRuntimeUrl).hostname!=="cdn.gpteng.co")throw Error("live specimen did not load the production CDN runtime");
 let fetchedBundleDigest=null;if(runtimeMode==="exact-branch"){const fetchedBundle=await specimen.evaluate(`fetch(${JSON.stringify(runtimeOverride.url)},{cache:"no-store"}).then(async response=>{if(!response.ok)throw Error("exact runtime fetch returned "+response.status);return response.text()})`);fetchedBundleDigest=digest(fetchedBundle);if(fetchedBundleDigest!==runtimeOverride.contentDigest||`sha256:${fetchedBundleDigest}`!==runtimeOverride.fingerprint)throw Error("fetched exact runtime content digest/fingerprint mismatch");if(hello.message.payload.scriptVersion!==runtimeOverride.scriptVersion)throw Error("iframe-reported runtime version does not match exact runtime contract");}
 before=await specimen.evaluate(snapshotExpression);
 await parent.evaluate(`(()=>{const child=[...document.querySelectorAll("iframe")].find(node=>node.src.includes("/__component/preview/"));if(!child)throw Error("live specimen frame missing");child.contentWindow.postMessage({type:"DS_SPECIMEN_PROPS",payload:{props:{variant:"destructive",disabled:true,children:"Agent review specimen "+Date.now()}}},new URL(child.src).origin);return true})()`);mutationSent=true;
 after=before;for(let i=0;i<40&&after===before;i++){await sleep(100);after=await specimen.evaluate(snapshotExpression);}
 list=await targets();if(!list.some(target=>target.id===liveId&&isSelectedLive(target)))throw Error("live iframe identity changed during specimen mutation");if(!list.some(target=>target.id===specimenId))throw Error("specimen iframe identity changed during mutation");
 if(after===before)throw Error("DS specimen prop mutation did not alter iframe DOM/computed style");
 if(JSON.parse(after).documentId!==JSON.parse(before).documentId)throw Error("DS specimen mutation crossed document identity");
 result={state:"ready",certifiedAt:new Date().toISOString(),projectId,connectivityRecovery,provenance:{servedMonorepoSha:servedSha,runtimeSource:{url:runtimeSourceUrl,contentDigest:runtimeContentDigest,declaredFingerprint:runtimeFingerprint,loadedUrl:loadedRuntimeUrl,runtimeContract:{mode:runtimeMode,url:loadedRuntimeUrl,contentDigest:fetchedBundleDigest??runtimeOverride?.contentDigest??null,fingerprint:runtimeOverride?.fingerprint??null,scriptVersion:hello.message.payload.scriptVersion}},liveSandboxUrl:live.url,iframeVite101:websocket,connectionHello:{transport:hello.transport,origin:hello.origin,sourceUrl:hello.sourceUrl,protocolVersion:hello.message.payload.protocolVersion,capabilities:hello.message.payload.capabilities},sameDocumentId:JSON.parse(before).documentId,navigationTimedOut,navigationRecovery:{attempts:navigationAttempts,recovered:recoveryNavigated},targetRecovery},liveIframe:live.url,liveTargetId:liveId,viteWebSocket:websocket,apiStatus,sandboxStart:{requestCount:startState.requestCount,status:startState.status,attempt:startRequest?{request:startRequest,response:startResponse}:null},sandboxAttach:replayedStarts?{mode:"authenticated-existing-url-replay",count:replayedStarts}:{mode:"direct-live-iframe",count:0},typedControls:{selection:canonicalSelection,...typedControls},runtime:{protocolVersion:hello.message.payload.protocolVersion,scriptVersion:hello.message.payload.scriptVersion,capabilities:hello.message.payload.capabilities,sessionId:hello.message.payload.sessionId,transport:{kind:hello.transport,origin:hello.origin,sourceUrl:hello.sourceUrl},canvas:{version:runtimeVersion,fingerprint:runtimeFingerprint,contentDigest:runtimeContentDigest,capabilities:runtimeCapabilities}},dom:{before:digest(before),after:digest(after)}};
}catch(error){failure=error;
}finally{
 if(mutationSent&&parent&&specimen&&before!==null){try{await parent.evaluate(`(()=>{const child=[...document.querySelectorAll("iframe")].find(node=>node.src.includes("/__component/preview/"));if(!child)throw Error("live specimen frame missing during reset");child.contentWindow.postMessage({type:"DS_SPECIMEN_PROPS",payload:{props:${JSON.stringify(fixtureSnapshot.specimenProps)}}},new URL(child.src).origin);return true})()`);restored=after;for(let i=0;i<40&&restored!==before;i++){await sleep(100);restored=await specimen.evaluate(snapshotExpression);}list=await targets();if(restored!==before)throw Error("DS specimen reset did not restore original DOM/computed style");if(!list.some(target=>target.id===liveId&&isSelectedLive(target))||!list.some(target=>target.id===specimenId))throw Error("iframe identity changed during specimen reset");if(result)result.dom={...result.dom,restored:digest(restored),restoredTargetIds:{live:liveId,specimen:specimenId}};}catch(resetError){failure=failure?new AggregateError([failure,resetError],"certification failed and specimen reset failed"):resetError;}}
 if(parent&&fixtureSnapshot){try{const cleanup=await parent.evaluate(`(()=>{const editor=window.__agentReviewEditor;if(!editor)throw Error('tldraw editor missing during cleanup');const before=${JSON.stringify(fixtureSnapshot)};const candidates=editor.getCurrentPageShapes().filter(shape=>shape.id!==before.canonicalShape?.id&&(String(shape.id).includes('candidate')||String(shape.props?.src??shape.props?.path??shape.meta?.sourcePath??'').includes('-candidate-')));const createdCandidates=candidates.filter(shape=>!before.candidateIds.includes(shape.id));const createdCandidateFiles=createdCandidates.map(shape=>shape.props?.src??shape.props?.path??shape.meta?.sourcePath).filter(path=>path&&!before.candidateFiles.includes(path));if(createdCandidates.length)editor.deleteShapes(createdCandidates.map(shape=>shape.id));if(before.canonicalShape&&editor.getShape(before.canonicalShape.id))editor.updateShape({id:before.canonicalShape.id,type:editor.getShape(before.canonicalShape.id).type,props:before.canonicalShape.props});if(editor.getCurrentPageId()!==before.pageId)editor.setCurrentPage(before.pageId);editor.select(...before.selectedShapeIds);return {removedCandidateIds:createdCandidates.map(shape=>shape.id),removedCandidateFiles:createdCandidateFiles,preservedCandidateIds:before.candidateIds,preservedCandidateFiles:before.candidateFiles}})()`);for(const path of cleanup.removedCandidateFiles){const encoded=path.split('/').map(encodeURIComponent).join('/');await parent.evaluate(`fetch('http://127.0.0.1:__API_PORT__/v1/git/files/${encoded}?project_id=${projectId}',{method:'DELETE',headers:{Authorization:${JSON.stringify(apiAuthorization)}}}).then(response=>{if(!response.ok&&response.status!==404)throw Error('candidate cleanup returned '+response.status)})`);}if(result)result.cleanup=cleanup;}catch(cleanupError){failure=failure?new AggregateError([failure,cleanupError],"certification failed and fixture cleanup failed"):cleanupError;}}
 specimen?.close();frame?.close();parent?.close();
}
if(failure)throw failure;
fs.writeFileSync(certification,JSON.stringify(result,null,2)+"\n");console.log(JSON.stringify(result));
'''
        replacements = {
            "__DEBUG__": str(self.ports.browser_debug),
            "__PROJECT__": json.dumps(self.project_id),
            "__BROWSER_URL__": json.dumps(f"http://localhost:{self.ports.browser}/projects/{self.project_id}?view=canvas&canvas=1&design-system-canvas=1&debug=1"),
            "__ALLOW__": "true" if self.allow_sandbox_start else "false",
            "__EXPECTED__": json.dumps(self.expected_sha),
            "__RUNTIME_MODE__": json.dumps(self.runtime_contract),
            "__BROWSER_TIMEOUT__": str(BROWSER_READINESS_TIMEOUT_MS),
            "__BROWSER_TIMEOUT_SECONDS__": str(BROWSER_READINESS_TIMEOUT_MS // 1000),
            "__API_PORT__": str(self.ports.browser_api_forward),
            "__COMPAT_PORT__": str(self.ports.compatibility_api_forward),
            "__ROOT__": json.dumps(str(self.root)),
        }
        for key, value in replacements.items():
            template = template.replace(key, value)
        return template

    def render_units(self) -> dict[str, str]:
        p = self.ports
        ssh = "/run/current-system/sw/bin/ssh " + " ".join([
            "-N", "-o StrictHostKeyChecking=no", "-o UserKnownHostsFile=/dev/null", "-o BatchMode=yes",
            "-o ExitOnForwardFailure=yes", "-o ServerAliveInterval=15", "-o ServerAliveCountMax=4", "-o ConnectTimeout=8",
            f"-L 127.0.0.1:{p.web_forward}:127.0.0.1:{p.vm_web}",
            f"-L 127.0.0.1:{p.browser_api_forward}:127.0.0.1:{p.vm_api}",
            f"-L 127.0.0.1:{p.compatibility_api_forward}:127.0.0.1:{p.vm_api}",
            f"{self.vm_user}@{self.vm_host}",
        ])
        common = f"Restart=always\nRestartSec=2\nStandardOutput=append:{self.root}"
        connectivity = f"""[Unit]\nDescription=Agent review {self.context_id} VM connectivity\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart={ssh}\n{common}/connectivity.log\nStandardError=append:{self.root}/connectivity.log\n"""
        proxy = f"""[Unit]\nDescription=Agent review {self.context_id} keyless browser proxy\nRequires={self.units['connectivity']}\nAfter={self.units['connectivity']}\n\n[Service]\nType=simple\nExecStart=/run/current-system/sw/bin/node {self.root}/keyless-proxy.mjs\n{common}/keyless-proxy.log\nStandardError=append:{self.root}/keyless-proxy.log\n"""
        runtime_dependency = f"Requires={self.units['runtime_https']}\nAfter={self.units['runtime_https']}\n" if self.exact_runtime_override else ""
        certificate_flag = "--ignore-certificate-errors " if self.exact_runtime_override else ""
        browser = f"""[Unit]\nDescription=Agent review {self.context_id} isolated authenticated browser\nRequires={self.units['keyless_proxy']}\nAfter={self.units['keyless_proxy']}\n{runtime_dependency}\n[Service]\nType=simple\nExecStart=/run/current-system/sw/bin/chromium --headless=new --disable-gpu --ozone-platform=headless --window-size=1920,1080 --user-data-dir={self.root}/browser-profile --remote-debugging-address=127.0.0.1 --remote-debugging-port={p.browser_debug} --disable-extensions {certificate_flag}--no-first-run --no-default-browser-check about:blank\nRestart=on-failure\nRestartSec=2\nStandardOutput=append:{self.root}/browser.log\nStandardError=append:{self.root}/browser.log\n"""
        units = {
            self.units["connectivity"]: connectivity,
            self.units["keyless_proxy"]: proxy,
            self.units["browser"]: browser,
        }
        if self.exact_runtime_override:
            units[self.units["runtime_https"]] = f"""[Unit]\nDescription=Agent review {self.context_id} exact-head runtime HTTPS\n\n[Service]\nType=simple\nExecStart=/run/current-system/sw/bin/node {self.root}/runtime-https.mjs\nRestart=on-failure\nStandardOutput=append:{self.root}/runtime-https.log\nStandardError=append:{self.root}/runtime-https.log\n"""
        return units

    def remote_setup_script(self, *, start: bool = True) -> str:
        p = self.ports
        unit = f"agent-review-{self.context_id}-vm.service"
        start_command = f'systemctl --user start "{unit}"' if start else f'systemctl --user stop "{unit}" >/dev/null 2>&1 || true'
        return f'''set -euo pipefail
export PATH="$HOME/.nix-profile/bin:/run/current-system/sw/bin:$HOME/.local/bin:$PATH"
repo="$HOME/src/lovable"
state="$HOME/.local/state/agent-review/{self.context_id}"
unit="agent-review-{self.context_id}-vm.service"
runtime_mode="{self.runtime_contract}"
mkdir -p "$state" "$HOME/.config/systemd/user"
if [ -x "$state/readiness.sh" ] && [ -f "$state/worktree" ] && [ "$(cat "$state/runtime-mode" 2>/dev/null || true)" = "$runtime_mode" ] && [ "$(git -C "$(cat "$state/worktree")" rev-parse HEAD 2>/dev/null || true)" = "{self.expected_sha}" ] && bash "$state/readiness.sh" "{self.expected_sha}" >/dev/null 2>&1; then
  printf '%s\n' "$(cat "$state/worktree")"
  exit 0
fi
systemctl --user stop "$unit" >/dev/null 2>&1 || true
resolve() {{
  local name="$1" installable="$2" marker="$state/tools/$1"
  mkdir -p "$state/tools"
  if [ -x "$marker" ]; then printf '%s\\n' "$marker"; return; fi
  local out
  out="$(nix build --no-link --print-out-paths "$installable")"
  ln -sfn "$out/bin/$name" "$marker"
  printf '%s\\n' "$marker"
}}
wt="$(resolve wt github:max-sixty/worktrunk/v0.37.0)"
git_lfs="$(resolve git-lfs nixpkgs#git-lfs)"
patchelf="$(resolve patchelf nixpkgs#patchelf)"
direnv="$(resolve direnv nixpkgs#direnv)"
export PATH="$(dirname "$git_lfs"):$(dirname "$wt"):$PATH"
git -C "$repo" fetch origin "+refs/heads/main:refs/remotes/origin/main"
git -C "$repo" fetch origin "pull/{self.pr}/head"
[ "$(git -C "$repo" rev-parse FETCH_HEAD)" = "{self.expected_sha}" ] || {{ echo 'remote fetched SHA mismatch' >&2; exit 1; }}
review_wt="$(git -C "$repo" worktree list --porcelain | awk '$1=="worktree"{{path=$2}} $1=="branch"&&$2=="refs/heads/review/pr-{self.pr}"{{print path}}')"
if [ -z "$review_wt" ]; then
  "$wt" switch -C "$repo" --create "review/pr-{self.pr}" --base "{self.expected_sha}" --no-hooks --yes --no-cd --format json >/dev/null
  review_wt="$(git -C "$repo" worktree list --porcelain | awk '$1=="worktree"{{path=$2}} $1=="branch"&&$2=="refs/heads/review/pr-{self.pr}"{{print path}}')"
  printf '%s|%s\n' "$review_wt" "{self.expected_sha}" >"$state/owned-worktree"
fi
[ -n "$review_wt" ] || {{ echo 'remote review worktree missing' >&2; exit 1; }}
[ -z "$(git -C "$review_wt" status --porcelain=v1)" ] || {{ echo 'remote review worktree is dirty' >&2; exit 1; }}
actual="$(git -C "$review_wt" rev-parse HEAD)"
if [ "$actual" != "{self.expected_sha}" ]; then
  git -C "$review_wt" merge-base --is-ancestor "$actual" "{self.expected_sha}" || {{ echo 'remote review worktree is not behind PR head' >&2; exit 1; }}
  git -C "$review_wt" reset --hard "{self.expected_sha}" >/dev/null
fi
[ "$(git -C "$review_wt" rev-parse HEAD)" = "{self.expected_sha}" ] || {{ echo 'remote review worktree SHA mismatch after update' >&2; exit 1; }}
(
  cd "$review_wt"
  git config --local filter.lfs.clean 'git-lfs clean -- %f'
  git config --local filter.lfs.smudge 'git-lfs smudge -- %f'
  git config --local filter.lfs.process 'git-lfs filter-process'
  git config --local filter.lfs.required true
  git lfs pull
  git lfs fsck
  [ -z "$(git status --porcelain=v1)" ] || {{ echo 'remote review worktree is dirty' >&2; exit 1; }}
  "$direnv" allow .
  CI=true "$direnv" exec . pnpm --config.enableGlobalVirtualStore=false install --force
  [ "$(CI=true "$direnv" exec . pnpm --config.enableGlobalVirtualStore=false config get enableGlobalVirtualStore)" = false ]
  [ -d node_modules/.pnpm ]
  {f'''CI=true "$direnv" exec . pnpm --dir script_tag build
  [ -f script_tag/dist/lovable.js ] || {{ echo 'exact-head script_tag bundle missing' >&2; exit 1; }}
  cp script_tag/dist/lovable.js "$state/lovable.js"''' if self.exact_runtime_override else ':'}
)
workerd="$(find -L "$review_wt/node_modules/.pnpm" -path '*/@cloudflare/workerd-linux-64/bin/workerd' -type f -print -quit)"
[ -n "$workerd" ] || {{ echo 'local Nix-patchable workerd missing' >&2; exit 1; }}
glibc_out="$(nix build --no-link --print-out-paths 'nixpkgs#glibc^out')"
interp="$(find "$glibc_out" -name ld-linux-x86-64.so.2 -print -quit)"
[ -n "$interp" ] && [ -x "$interp" ] || {{ echo 'Nix glibc interpreter missing' >&2; exit 1; }}
"$patchelf" --set-interpreter "$interp" --set-rpath "$glibc_out/lib" "$workerd"
"$workerd" --version >"$state/workerd-version.txt"
cat >"$state/{unit}" <<UNIT
[Unit]
Description=Agent review {self.context_id} exact-head VM slice
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$review_wt
Environment=CI=true
Environment=npm_config_enable_global_virtual_store=false
Environment=PNPM_CONFIG_ENABLE_GLOBAL_VIRTUAL_STORE=false
Environment=GO_SCHEDULER_BASE_URL=https://sandbox-scheduler.gcp-euw4.d.l5e.io
Environment=GO_SCHEDULER_GRPC_ADDR=https://sandbox-scheduler.gcp-euw4.d.l5e.io
Environment=VITE_GIT_COMMIT_SHA={self.expected_sha}
ExecStart=/bin/sh -lc 'exec $direnv exec . devenv wt --no-tui --base-port {p.vm_web}'
Restart=on-failure
RestartSec=2
StandardOutput=append:$state/vm-slice.log
StandardError=append:$state/vm-slice.log
UNIT
ln -sfn "$state/{unit}" "$HOME/.config/systemd/user/{unit}"
systemctl --user daemon-reload
{start_command}
printf '%s\\n' "$review_wt" >"$state/worktree"
printf '%s\\n' "$runtime_mode" >"$state/runtime-mode"
cat >"$state/readiness.sh" <<'CHECK'
set -euo pipefail
expected="$1"
state="$HOME/.local/state/agent-review/{self.context_id}"
unit="{unit}"
worktree="$(cat "$state/worktree")"
[ "$(git -C "$worktree" rev-parse HEAD)" = "$expected" ]
[ -z "$(git -C "$worktree" status --porcelain=v1)" ]
systemctl --user is-active --quiet "$unit"
environment="$(systemctl --user show -p Environment --value "$unit")"
case "$environment" in *PNPM_CONFIG_ENABLE_GLOBAL_VIRTUAL_STORE=false*) ;; *) exit 1;; esac
case "$environment" in *GO_SCHEDULER_BASE_URL=https://sandbox-scheduler.gcp-euw4.d.l5e.io*) ;; *) exit 1;; esac
case "$environment" in *GO_SCHEDULER_GRPC_ADDR=https://sandbox-scheduler.gcp-euw4.d.l5e.io*) ;; *) exit 1;; esac
case "$environment" in *VITE_GIT_COMMIT_SHA={self.expected_sha}*) ;; *) exit 1;; esac
curl -fsS "http://127.0.0.1:{p.vm_web + 1}/processes" | python3 -c '
import json,sys
value=json.load(sys.stdin)
items=value if isinstance(value,list) else value.get("processes",value.get("data",[]))
if isinstance(items,dict): items=[dict(item) | {{"name":name}} for name,item in items.items()]
def ready(needle):
    found=[item for item in items if needle in str(item.get("name","")).lower()]
    return found and all(str(item.get("status",item.get("namespace",""))).lower() in {{"ready","running","completed"}} for item in found)
for required in ("web", "api", "temporal"):
    if not ready(required): raise SystemExit(f"{{required}} service not ready")
'
CHECK
chmod 700 "$state/readiness.sh"
'''

    def prepare_vm(self, *, start: bool = True) -> None:
        command = [
            "/run/current-system/sw/bin/ssh", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8", f"{self.vm_user}@{self.vm_host}", "bash", "-s",
        ]
        result = subprocess.run(
            command, input=self.remote_setup_script(start=start), capture_output=True, text=True, timeout=600,
        )
        if result.returncode:
            detail = "\n".join(part for part in (result.stderr.strip(), result.stdout.strip()) if part)
            raise RuntimeError(f"VM setup failed: {detail}")
        if self.exact_runtime_override:
            destination = f"{self.vm_user}@{self.vm_host}:$HOME/.local/state/agent-review/{self.context_id}/lovable.js"
            copied = run(["/run/current-system/sw/bin/scp", "-o", "BatchMode=yes", destination, str(self.root / "lovable.js")], timeout=30, check=False)
            if copied.returncode:
                raise RuntimeError(f"could not copy exact-head runtime bundle: {copied.stderr.strip()}")
            cert = self.root / "runtime-cert.pem"
            key = self.root / "runtime-key.pem"
            generated = run(["/run/current-system/sw/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-keyout", str(key), "-out", str(cert)], timeout=30, check=False)
            if generated.returncode:
                raise RuntimeError(f"could not create context runtime certificate: {generated.stderr.strip()}")
            runtime_url = f"https://localhost:{self.ports.browser + 1}/lovable.js"
            digest = __import__("hashlib").sha256((self.root / "lovable.js").read_bytes()).hexdigest()
            package = json.loads((self.worktree / "script_tag/package.json").read_text())
            script_version = package.get("version")
            if not isinstance(script_version, str) or not script_version:
                raise RuntimeError("exact-branch script_tag package version is missing")
            contract = {"url": runtime_url, "contentDigest": digest, "fingerprint": f"sha256:{digest}", "scriptVersion": script_version, "expectedSha": self.expected_sha}
            (self.root / "runtime-override.json").write_text(json.dumps(contract, indent=2) + "\n")

    def write(self) -> HarnessContext:
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / "keyless-proxy.mjs").write_text(self.render_proxy())
        (self.root / "readiness.mjs").write_text(self.render_readiness())
        (self.root / "browser-readiness.mjs").write_text(self.render_browser_readiness())
        if self.exact_runtime_override:
            (self.root / "runtime-https.mjs").write_text(
                f'import https from "node:https";import fs from "node:fs";import crypto from "node:crypto";\n'
                f'const root={json.dumps(str(self.root))},port={self.ports.browser + 1};\n'
                'const bundle=fs.readFileSync(`${root}/lovable.js`),meta=JSON.parse(fs.readFileSync(`${root}/runtime-override.json`));\n'
                'const digest=crypto.createHash("sha256").update(bundle).digest("hex");if(digest!==meta.contentDigest||`sha256:${digest}`!==meta.fingerprint)throw Error("runtime bundle content digest/fingerprint mismatch");\n'
                'https.createServer({key:fs.readFileSync(`${root}/runtime-key.pem`),cert:fs.readFileSync(`${root}/runtime-cert.pem`)},(req,res)=>{if(new URL(req.url,"https://localhost").pathname!=="/lovable.js"){res.writeHead(404);res.end();return;}res.writeHead(200,{"content-type":"text/javascript","cache-control":"no-store","access-control-allow-origin":"*","content-length":bundle.length});res.end(bundle);}).listen(port,"127.0.0.1");\n'
            )
        (self.root / "readiness.sh").write_text(
            "set -eu\n/run/current-system/sw/bin/node " + shlex.quote(str(self.root / "readiness.mjs"))
            + "\n/run/current-system/sw/bin/node " + shlex.quote(str(self.root / "browser-readiness.mjs")) + "\n"
        )
        (self.root / "readiness.sh").chmod(0o700)
        for name, body in self.render_units().items():
            (self.root / name).write_text(body)
        context = self.context()
        payload = asdict(context)
        payload["ports"] = asdict(context.ports)
        (self.root / "context.json").write_text(json.dumps(payload, indent=2) + "\n")
        return context

    def prepare_browser_profile(self) -> None:
        profile = self.root / "browser-profile"
        if profile.exists() and any(profile.iterdir()):
            return
        seed = self.browser_profile_seed
        if seed is None or not seed.is_dir():
            raise RuntimeError("manual-test browser requires --browser-profile-seed with an authenticated, stopped Chromium profile")
        if any((seed / name).exists() for name in ("SingletonLock", "SingletonSocket", "SingletonCookie")):
            raise RuntimeError("browser profile seed appears active; stop its Chromium process before cloning")
        shutil.copytree(seed, profile, dirs_exist_ok=True, symlinks=True)

    def start(self) -> None:
        self.prepare_browser_profile()
        unit_dir = self.home / ".config/systemd/user"
        unit_dir.mkdir(parents=True, exist_ok=True)
        ordered_units = [self.units["connectivity"], self.units["keyless_proxy"]]
        if self.exact_runtime_override:
            ordered_units.append(self.units["runtime_https"])
        ordered_units.append(self.units["browser"])
        for name in ordered_units:
            link = unit_dir / name
            target = self.root / name
            if link.is_symlink() and link.resolve() != target:
                link.unlink()
            if not link.exists():
                link.symlink_to(target)
        run(["systemctl", "--user", "daemon-reload"])
        run(["systemctl", "--user", "start", *ordered_units], timeout=20)


def teardown_context(home: Path, context_id: str, *, remove_state: bool = True) -> None:
    if not __import__("re").fullmatch(r"pr-[0-9]+", context_id):
        raise RuntimeError("context id must be pr-N")
    root = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "agent-review" / context_id
    metadata = root / "context.json"
    if not metadata.is_file():
        raise RuntimeError(f"unknown agent-review context: {context_id}")
    data = json.loads(metadata.read_text())
    if data.get("context_id") != context_id:
        raise RuntimeError("context metadata identity mismatch")
    units = list(data.get("units", {}).values())
    remote_units = list(data.get("remote_units", {}).values())
    expected_prefix = f"agent-review-{context_id}-"
    if not units or any(not unit.startswith(expected_prefix) or not unit.endswith(".service") for unit in units + remote_units):
        raise RuntimeError("context metadata contains unsafe unit names")
    run(["systemctl", "--user", "stop", *reversed(units)], timeout=20, check=False)
    if remote_units:
        destination = f"{data['vm_user']}@{data['vm_host']}"
        quoted = " ".join(shlex.quote(unit) for unit in remote_units)
        links = " ".join(f'"$HOME/.config/systemd/user/{unit}"' for unit in remote_units)
        remote_root = f'"$HOME/.local/state/agent-review/{context_id}"'
        command = f"systemctl --user stop {quoted}; rm -f {links}; systemctl --user daemon-reload; rm -rf {remote_root}"
        run(["/run/current-system/sw/bin/ssh", "-o", "BatchMode=yes", destination, command], timeout=20, check=False)
    for unit in units:
        link = home / ".config/systemd/user" / unit
        if link.is_symlink() and root in link.resolve().parents:
            link.unlink()
    run(["systemctl", "--user", "daemon-reload"], check=False)
    if remove_state:
        shutil.rmtree(root)
