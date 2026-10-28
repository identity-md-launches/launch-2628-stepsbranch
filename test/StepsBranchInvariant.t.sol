// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StepsBranch, IIntake} from "../src/StepsBranch.sol";
import {MockToken} from "../src/MockToken.sol";

interface InvVm {
    function prank(address) external;
    function warp(uint256) external;
}

/// Same-chain Intake model: real token pull, tuple callback, completes each request once and
/// calls back inside a try under the fixed 200,000 gas stipend, like the public Intake v2.
contract InvariantIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    struct Request {
        address target;
        bytes4 success;
        bytes4 failure;
        bool completed;
    }

    mapping(bytes32 => Request) public requests;
    bytes32[] public ids;
    uint256 public nonce;

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata cb,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        require(action == bytes32("job.open@job-1") && body.length > 0, "request shape");
        require(cb.target == msg.sender && cb.selector == 0x4374622e && failure == 0x5a0df71e, "callback shape");
        require(MockToken(asset).transferFrom(msg.sender, address(this), amount), "token pull");
        id = keccak256(abi.encode(address(this), ++nonce));
        requests[id] = Request(cb.target, cb.selector, failure, false);
        ids.push(id);
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function deliver(bytes32 id, bytes32 hash, string calldata uri) external returns (bool delivered) {
        Request storage r = requests[id];
        require(r.target != address(0) && !r.completed, "not open");
        r.completed = true;
        (delivered,) = r.target.call{gas: 200_000}(abi.encodeWithSelector(r.success, id, hash, uri));
    }

    function fail(bytes32 id, uint8 status, bytes32 reason) external returns (bool delivered) {
        Request storage r = requests[id];
        require(r.target != address(0) && !r.completed, "not open");
        r.completed = true;
        (delivered,) = r.target.call{gas: 200_000}(
            abi.encodeWithSelector(r.failure, id, status, reason, uint16(3), uint16(5), bytes(""))
        );
    }
}

contract StepsHandler {
    struct FrozenProposal {
        bool set;
        StepsBranch.Status status;
        bytes32 requestId;
        bytes32 reason;
    }

    struct FrozenCheckpoint {
        bool set;
        bytes32 resultHash;
        bytes32 uriHash;
        bytes32 digest;
        uint256 proposalId;
        uint64 branchId;
        uint64 revision;
        bytes32 parent;
    }

    struct FrozenReceipt {
        bool set;
        uint8 status;
        bytes32 resultHash;
        bytes32 uriHash;
        bytes32 reason;
    }

    mapping(uint256 => FrozenProposal) internal frozenProposal;
    mapping(uint256 => FrozenCheckpoint) internal frozenCheckpoint;
    mapping(uint256 => FrozenReceipt) internal frozenReceipt;

    modifier observed() {
        _;
        _observe();
    }

    function _observe() internal {
        uint256 n = ledger.proposalCount();
        for (uint256 id; id < n; ++id) {
            (, uint64 branchId, StepsBranch.Status s,,,,, bytes32 requestId, bytes32 reason,) = ledger.proposals(id);
            branchId;
            FrozenProposal storage f = frozenProposal[id];
            if (f.set) {
                if (s != f.status || requestId != f.requestId || reason != f.reason) {
                    _fail("terminal proposal reopened");
                }
            } else if (uint8(s) >= 2) {
                frozenProposal[id] = FrozenProposal(true, s, requestId, reason);
            }
            (bool received, uint8 st, bytes32 rh, bytes32 uh, bytes32 rr) = ledger.lateReceiptOf(id);
            FrozenReceipt storage fr = frozenReceipt[id];
            if (fr.set) {
                if (!received || st != fr.status || rh != fr.resultHash || uh != fr.uriHash || rr != fr.reason) {
                    _fail("late receipt overwritten");
                }
            } else if (received) {
                if (s != StepsBranch.Status.Expired) _fail("late receipt without expiry");
                if (st == 0 && rh == bytes32(0)) _fail("late success without result hash");
                if (st != 0 && rh != bytes32(0)) _fail("late failure with result hash");
                frozenReceipt[id] = FrozenReceipt(true, st, rh, uh, rr);
            }
        }
        for (uint256 c; c < ledger.count(); ++c) {
            StepsBranch.CheckpointView memory v = ledger.checkpoint(c);
            FrozenCheckpoint storage fc = frozenCheckpoint[c];
            if (fc.set) {
                if (
                    fc.resultHash != v.resultHash || fc.uriHash != v.uriHash || fc.digest != v.digest
                        || fc.proposalId != v.proposalId || fc.branchId != v.branchId || fc.revision != v.revision
                        || fc.parent != v.parent
                ) _fail("checkpoint mutated");
            } else {
                frozenCheckpoint[c] = FrozenCheckpoint(
                    true, v.resultHash, v.uriHash, v.digest, v.proposalId, v.branchId, v.revision, v.parent
                );
            }
        }
    }
    InvVm private constant vm = InvVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    StepsBranch public immutable ledger;
    InvariantIntake public immutable intake;
    MockToken public immutable token;
    address public immutable owner;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    address public constant STRANGER = address(0x5757);

    uint256 public constant MINTED_EACH = 1_000 ether;

    // Ghost accounting.
    uint256 public ghostPaid;
    uint256 public ghostFunded;
    uint256 public ghostSuccessDelivered;
    uint256 public ghostLateDelivered;
    uint256 public ghostLostCallbacks;
    uint256 public ghostForeignAccepted;
    uint256 public ghostBadSuccessAccepted;

    // Result bytes per checkpoint so that snapshot forks can be made with the real JSON.
    mapping(bytes32 => bytes) public resultOfHash;
    mapping(bytes32 => bytes) internal bodyOfHash;
    uint256 public calls;
    string public violation;

    function _fail(string memory why) internal {
        if (bytes(violation).length == 0) violation = why;
    }

    constructor(StepsBranch ledger_, InvariantIntake intake_, MockToken token_, address owner_) {
        ledger = ledger_;
        intake = intake_;
        token = token_;
        owner = owner_;
        for (uint256 i; i < 3; ++i) {
            token.mint(actors[i], MINTED_EACH);
            vm.prank(actors[i]);
            token.approve(address(ledger), type(uint256).max);
        }
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _body(uint256 seed) internal pure returns (bytes memory) {
        return bytes(string.concat('{"objective":"step ', _u(seed % 1000), '","skill":"research-report"}'));
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) {
            b = abi.encodePacked(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }

    function _head(uint64 id) internal view returns (bytes32 h) {
        (h,,,) = ledger.branches(id);
    }

    function _proposal(uint256 id)
        internal
        view
        returns (uint64 branchId, StepsBranch.Status s, bytes32 bodyHash, bytes32 requestId)
    {
        (, branchId, s,,,, bodyHash, requestId,,) = ledger.proposals(id);
    }

    // ---- actions ----

    function propose(uint256 actorSeed, uint256 branchSeed, uint256 bodySeed, bool stale) external observed {
        calls++;
        uint64 branchId = uint64(branchSeed % ledger.branchCount());
        bytes32 anchor = stale ? keccak256(abi.encode(bodySeed)) : _head(branchId);
        bytes memory body = _body(bodySeed);
        bodyOfHash[keccak256(body)] = body;
        vm.prank(_actor(actorSeed));
        try ledger.propose(branchId, anchor, body) {
            if (stale && anchor != _head(branchId)) _fail("stale anchor accepted");
        } catch {
            if (anchor == _head(branchId)) _fail("current-head proposal refused");
        }
    }

    function fund(uint256 actorSeed, uint256 proposalSeed, uint256 maxSeed) external observed {
        calls++;
        uint256 n = ledger.proposalCount();
        if (n == 0) return;
        uint256 id = proposalSeed % n;
        (,,,,,, bytes32 bodyHash,,,) = ledger.proposals(id);
        bytes memory body = bodyOfHash[bodyHash];
        uint256 price = ledger.price();
        uint256 maxPayment = _bound(maxSeed, price - (price > 1 ? 1 : 0), price + 1 ether);
        address who = _actor(actorSeed);
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        try ledger.fundWithPayment(id, body, maxPayment) returns (bytes32) {
            if (price > maxPayment) _fail("funded above caller maximum");
            if (token.balanceOf(who) != before - price) _fail("funder not debited exactly price");
            ghostPaid += price;
            ghostFunded++;
        } catch {
            if (token.balanceOf(who) != before) _fail("failed funding moved tokens");
        }
    }

    function _openRequest(uint256 seed) internal view returns (bytes32 id, bool found) {
        uint256 n = intake.idCount();
        if (n == 0) return (bytes32(0), false);
        uint256 start = seed % n;
        for (uint256 i; i < n; ++i) {
            id = intake.ids((start + i) % n);
            (,,, bool completed) = intake.requests(id);
            if (!completed) return (id, true);
        }
        return (bytes32(0), false);
    }

    function deliverSuccess(uint256 reqSeed, uint256 resultSeed, uint256 uriSeed) external observed {
        calls++;
        (bytes32 req, bool found) = _openRequest(reqSeed);
        if (!found) return;
        uint256 pid = ledger.proposalOfRequest(req) - 1;
        (, StepsBranch.Status s,,) = _proposal(pid);
        bytes memory result = bytes(string.concat('{"jobId":"', _u(resultSeed % 100000), '","files":[]}'));
        bytes32 h = keccak256(result);
        resultOfHash[h] = result;
        uint256 len = uriSeed % 4 == 0 ? _bound(uriSeed, 2040, 2056) : _bound(uriSeed, 0, 300);
        bytes memory uri = new bytes(len);
        for (uint256 i; i < len; ++i) {
            uri[i] = "u";
        }
        bool delivered = intake.deliver(req, h, string(uri));
        if (!delivered) ghostLostCallbacks++;
        else if (s == StepsBranch.Status.Expired) ghostLateDelivered++;
        else ghostSuccessDelivered++;
    }

    function deliverFailure(uint256 reqSeed, bool refused, bytes32 reason) external observed {
        calls++;
        (bytes32 req, bool found) = _openRequest(reqSeed);
        if (!found) return;
        uint256 pid = ledger.proposalOfRequest(req) - 1;
        (, StepsBranch.Status s,,) = _proposal(pid);
        bool delivered = intake.fail(req, refused ? 1 : 2, reason);
        if (!delivered) ghostLostCallbacks++;
        else if (s == StepsBranch.Status.Expired) ghostLateDelivered++;
    }

    function expire(uint256 proposalSeed, uint256 actorSeed) external observed {
        calls++;
        uint256 n = ledger.proposalCount();
        if (n == 0) return;
        vm.prank(_actor(actorSeed));
        try ledger.expirePending(proposalSeed % n) {} catch {}
    }

    function warp(uint256 secondsSeed) external observed {
        calls++;
        vm.warp(block.timestamp + _bound(secondsSeed, 1, 8 days));
    }

    function fork(uint256 checkpointSeed) external observed {
        calls++;
        uint256 n = ledger.count();
        if (n == 0) return;
        try ledger.fork(checkpointSeed % n) {}
        catch {
            _fail("reference fork of a known checkpoint failed");
        }
    }

    function forkWithSnapshot(uint256 checkpointSeed, bool tamper) external observed {
        calls++;
        uint256 n = ledger.count();
        if (n == 0) return;
        uint256 cid = checkpointSeed % n;
        bytes memory json = resultOfHash[ledger.checkpoint(cid).resultHash];
        if (tamper) {
            bytes memory bad = bytes.concat(json, " ");
            try ledger.forkWithSnapshot(cid, bad) {
                _fail("tampered snapshot accepted");
            } catch {}
            return;
        }
        try ledger.forkWithSnapshot(cid, json) returns (uint64 child) {
            if (keccak256(ledger.snapshotOf(child)) != keccak256(json)) _fail("snapshot bytes differ");
        } catch {
            _fail("exact snapshot refused");
        }
    }

    function forkFromOrigin() external observed {
        calls++;
        ledger.forkFromOrigin();
    }

    function setPrice(uint256 priceSeed, bool asOwner) external observed {
        calls++;
        uint256 next = _bound(priceSeed, 1, 3 ether);
        vm.prank(asOwner ? owner : STRANGER);
        try ledger.setPrice(next) {
            if (!asOwner) _fail("stranger changed price");
        } catch {
            if (asOwner) _fail("owner could not change price");
        }
    }

    /// A caller other than the Intake must never settle anything, even with a real request id.
    function foreignCallback(uint256 reqSeed, bool success) external observed {
        calls++;
        uint256 n = intake.idCount();
        if (n == 0) return;
        bytes32 req = intake.ids(reqSeed % n);
        vm.prank(STRANGER);
        if (success) {
            try ledger.onResult(req, keccak256("forged"), "ipfs://forged") {
                ghostForeignAccepted++;
            } catch {}
        } else {
            try ledger.onFailure(req, 1, "forged", 0, 0, "") {
                ghostForeignAccepted++;
            } catch {}
        }
    }

    /// The Intake itself, with an id it never issued for this ledger or a zero hash.
    function badIntakeCallback(bytes32 unknownId, uint256 reqSeed) external observed {
        calls++;
        vm.prank(address(intake));
        try ledger.onResult(keccak256(abi.encode("unknown", unknownId)), keccak256("x"), "") {
            ghostBadSuccessAccepted++;
        } catch {}
        uint256 n = intake.idCount();
        if (n == 0) return;
        vm.prank(address(intake));
        try ledger.onResult(intake.ids(reqSeed % n), bytes32(0), "") {
            ghostBadSuccessAccepted++;
        } catch {}
        vm.prank(address(intake));
        try ledger.onFailure(intake.ids(reqSeed % n), 0, "x", 0, 0, "") {
            ghostBadSuccessAccepted++;
        } catch {}
    }
}

contract StepsBranchInvariantTest {
    StepsBranch internal ledger;
    InvariantIntake internal intake;
    MockToken internal token;
    StepsHandler internal handler;
    address internal constant OWNER = address(0x0bCeD6bf6f6dB1D7aC5Bc0B540482D170a027352);

    function setUp() public {
        token = new MockToken();
        intake = new InvariantIntake();
        ledger = new StepsBranch(IIntake(address(intake)), address(token), 0.5 ether, OWNER);
        handler = new StepsHandler(ledger, intake, token, OWNER);
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    function _p(uint256 id)
        internal
        view
        returns (uint64 branchId, StepsBranch.Status s, bytes32 requestId, bytes32 reason)
    {
        (, branchId, s,,,,, requestId, reason,) = ledger.proposals(id);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_paymentIsForwardedExactlyAndNothingIsHeld() public view {
        require(token.balanceOf(address(ledger)) == 0, "ledger holds tokens");
        require(token.allowance(address(ledger), address(intake)) == 0, "residual intake approval");
        require(token.balanceOf(address(intake)) == handler.ghostPaid(), "intake received != paid");
        uint256 actorsHeld;
        for (uint256 i; i < 3; ++i) {
            actorsHeld += token.balanceOf(handler.actors(i));
        }
        require(actorsHeld + token.balanceOf(address(intake)) == 3 * handler.MINTED_EACH(), "supply not conserved");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_callbacksAreAuthenticatedAndNeverLost() public view {
        require(handler.ghostForeignAccepted() == 0, "foreign callback accepted");
        require(handler.ghostBadSuccessAccepted() == 0, "unknown id, zero hash or status 0 failure accepted");
        require(handler.ghostLostCallbacks() == 0, "authenticated callback not delivered under 200000 gas");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_pendingSlotsAndCheckpointsAreConsistent() public view {
        uint256 n = ledger.proposalCount();
        uint256 pendingCount;
        uint256 succeeded;
        uint256 funded;
        for (uint256 id; id < n; ++id) {
            (uint64 branchId, StepsBranch.Status s, bytes32 requestId,) = _p(id);
            require(branchId < ledger.branchCount(), "proposal on unknown branch");
            if (s == StepsBranch.Status.Draft) {
                require(requestId == bytes32(0), "draft has a request");
                require(ledger.proposalOfRequest(requestId) == 0, "zero request id admitted");
            } else {
                funded++;
                require(requestId != bytes32(0) && ledger.proposalOfRequest(requestId) == id + 1, "request index");
            }
            if (s == StepsBranch.Status.Pending) {
                pendingCount++;
                (,,, uint64 pendingPlusOne) = ledger.branches(branchId);
                require(pendingPlusOne == id + 1, "pending proposal not in its branch slot");
            }
            if (s == StepsBranch.Status.Succeeded) succeeded++;
            (bool received, uint8 st,,,) = ledger.lateReceiptOf(id);
            if (s != StepsBranch.Status.Expired) require(!received && st == 0, "late receipt on non-expired proposal");
        }
        require(funded == handler.ghostFunded(), "funded count");
        require(succeeded == ledger.count(), "checkpoints != succeeded proposals");
        require(succeeded == handler.ghostSuccessDelivered(), "checkpoints != on-time successes");

        uint256 busy;
        for (uint64 b; b < ledger.branchCount(); ++b) {
            (bytes32 head, uint64 revision, uint64 headPlusOne, uint64 pendingPlusOne) = ledger.branches(b);
            if (pendingPlusOne != 0) {
                busy++;
                (uint64 pb, StepsBranch.Status ps,,) = _p(pendingPlusOne - 1);
                require(pb == b && ps == StepsBranch.Status.Pending, "branch slot points at a non-pending proposal");
            }
            if (headPlusOne == 0) {
                require(head == bytes32(0) && revision == 0, "origin branch with a head");
            } else {
                StepsBranch.CheckpointView memory c = ledger.checkpoint(headPlusOne - 1);
                require(head == c.digest && revision == c.revision, "head does not match its checkpoint");
            }
        }
        require(busy == pendingCount, "pending proposals != busy branches");

        for (uint256 c; c < ledger.count(); ++c) {
            StepsBranch.CheckpointView memory v = ledger.checkpoint(c);
            (, StepsBranch.Status s,,) = _p(v.proposalId);
            require(s == StepsBranch.Status.Succeeded, "checkpoint for a non-succeeded proposal");
            require(v.resultHash != bytes32(0), "zero result hash checkpoint");
            if (c > 0) require(ledger.checkpoint(c - 1).proposalId != v.proposalId, "two checkpoints, one proposal");
        }
    }

    /// Terminal states, checkpoints and late receipts are frozen: the handler records each one
    /// when it first appears and compares it after every later call (see StepsHandler._observe).
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_finishedRecordsNeverChange() public view {
        string memory v = handler.violation();
        require(bytes(v).length == 0, v);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_authorityIsOnlyTheExplicitOwner() public view {
        require(ledger.owner() == OWNER, "owner changed without a two-step transfer");
        require(ledger.pendingOwner() == address(0), "pending owner appeared");
        require(address(ledger.intake()) == address(intake) && ledger.asset() == address(token), "binding changed");
        require(ledger.price() != 0, "zero price");
    }
}
