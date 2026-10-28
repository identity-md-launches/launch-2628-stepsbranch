// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StepsBranch, IIntake} from "../src/StepsBranch.sol";
import {MockToken} from "../src/MockToken.sol";
import {DocumentedIntake} from "./StepsBranch.t.sol";

interface EdgeVm {
    function prank(address) external;
    function warp(uint256) external;
    function expectRevert(bytes4) external;
}

/// Pulls less than the amount it was asked to take.
contract ShortPullIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    uint256 public shortBy;
    uint256 public nonce;

    constructor(uint256 shortBy_) {
        shortBy = shortBy_;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address asset, uint256 amount)
        external
        returns (bytes32)
    {
        if (amount > shortBy) MockToken(asset).transferFrom(msg.sender, address(this), amount - shortBy);
        return bytes32(++nonce);
    }
}

/// Answers synchronously from inside the request, as no real Intake does: the ledger must refuse it.
contract EagerIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    bool public delivered;
    uint256 public nonce;

    function requestWithFailure(bytes32, bytes calldata, Callback calldata cb, bytes4, address asset, uint256 amount)
        external
        returns (bytes32 id)
    {
        MockToken(asset).transferFrom(msg.sender, address(this), amount);
        id = bytes32(++nonce);
        (delivered,) = cb.target.call{gas: 200_000}(abi.encodeWithSelector(cb.selector, id, keccak256("eager"), ""));
    }
}

/// Burns one unit on every transfer.
contract FeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address a, uint256 n) external {
        balanceOf[a] += n;
    }

    function approve(address s, uint256 n) external returns (bool) {
        allowance[msg.sender][s] = n;
        return true;
    }

    function transferFrom(address a, address b, uint256 n) external returns (bool) {
        allowance[a][msg.sender] -= n;
        balanceOf[a] -= n;
        balanceOf[b] += n - 1;
        return true;
    }
}

contract StepsBranchEdgesTest {
    EdgeVm private constant vm = EdgeVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes internal constant BODY = '{"objective":"Edge step","skill":"research-report"}';
    bytes internal constant RESULT = '{"jobId":"edge-job","files":[]}';
    string internal constant URI = "ipfs://bafybeiddvhj22nmr4vbvcukumtqoi6sdnheqqxqidqod36lxb73zyi7pny/result.json";
    uint256 internal constant PRICE = 0.5 ether;
    address internal constant OWNER = address(0x0bCeD6bf6f6dB1D7aC5Bc0B540482D170a027352);
    address internal constant STRANGER = address(0x5757);

    StepsBranch internal ledger;
    DocumentedIntake internal intake;
    MockToken internal token;

    function setUp() public {
        token = new MockToken();
        intake = new DocumentedIntake();
        ledger = new StepsBranch(IIntake(address(intake)), address(token), PRICE, OWNER);
        token.mint(address(this), 100 ether);
        token.approve(address(ledger), type(uint256).max);
    }

    function _status(uint256 id) internal view returns (StepsBranch.Status s) {
        (,, s,,,,,,,) = ledger.proposals(id);
    }

    function _branch(uint64 id)
        internal
        view
        returns (bytes32 head, uint64 revision, uint64 headPlusOne, uint64 pending)
    {
        return ledger.branches(id);
    }

    function _late(uint256 id)
        internal
        view
        returns (bool received, uint8 status, bytes32 resultHash, bytes32 uriHash, bytes32 reason)
    {
        return ledger.lateReceiptOf(id);
    }

    function _fund(uint64 branchId) internal returns (uint256 id, bytes32 request) {
        (bytes32 head,,,) = ledger.branches(branchId);
        id = ledger.propose(branchId, head, BODY);
        request = ledger.fundWithPayment(id, BODY, PRICE);
    }

    function _uri(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            b[i] = "a";
        }
        return string(b);
    }

    // ---- configuration ----

    function testStatusNumberingAndConstants() public view {
        require(uint8(StepsBranch.Status.Draft) == 0 && uint8(StepsBranch.Status.Pending) == 1, "0,1");
        require(uint8(StepsBranch.Status.Succeeded) == 2 && uint8(StepsBranch.Status.Refused) == 3, "2,3");
        require(uint8(StepsBranch.Status.Failed) == 4 && uint8(StepsBranch.Status.Expired) == 5, "4,5");
        require(ledger.PENDING_TIMEOUT() == 7 days && ledger.MAX_SNAPSHOT_BYTES() == 4096, "limits");
        require(ledger.MAX_EVENT_URI_BYTES() == 2048 && ledger.MAX_BODY_BYTES() == 16384, "limits");
        require(ledger.ACTION() == bytes32("job.open@job-1"), "action");
        require(ledger.ON_RESULT() == bytes4(keccak256("onResult(bytes32,bytes32,string)")), "result selector");
        require(
            ledger.ON_FAILURE() == bytes4(keccak256("onFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)")),
            "failure selector"
        );
        require(ledger.owner() == OWNER && ledger.pendingOwner() == address(0), "owner");
        require(ledger.branchCount() == 1 && ledger.count() == 0 && ledger.proposalCount() == 0, "empty ledger");
    }

    function testConstructorRejectsEachZeroArgument() public {
        vm.expectRevert(StepsBranch.InvalidConfiguration.selector);
        new StepsBranch(IIntake(address(0)), address(token), PRICE, OWNER);
        vm.expectRevert(StepsBranch.InvalidConfiguration.selector);
        new StepsBranch(IIntake(address(intake)), address(0), PRICE, OWNER);
        vm.expectRevert(StepsBranch.InvalidConfiguration.selector);
        new StepsBranch(IIntake(address(intake)), address(token), 0, OWNER);
    }

    function testConstructorDoesNotAssignDeployerOrOrigin() public {
        StepsBranch fresh = new StepsBranch(IIntake(address(intake)), address(token), PRICE, OWNER);
        require(fresh.owner() == OWNER && fresh.owner() != address(this) && fresh.owner() != tx.origin, "owner");
        vm.prank(address(this));
        vm.expectRevert(StepsBranch.NotOwner.selector);
        fresh.setPrice(1);
    }

    // ---- owner powers ----

    function testOnlyOwnerSetsNonzeroPrice() public {
        vm.prank(STRANGER);
        vm.expectRevert(StepsBranch.NotOwner.selector);
        ledger.setPrice(1 ether);
        vm.prank(OWNER);
        vm.expectRevert(StepsBranch.InvalidConfiguration.selector);
        ledger.setPrice(0);
        vm.prank(OWNER);
        ledger.setPrice(1 ether);
        require(ledger.price() == 1 ether, "price");
    }

    function testTwoStepOwnershipFailurePaths() public {
        vm.prank(STRANGER);
        vm.expectRevert(StepsBranch.NotOwner.selector);
        ledger.transferOwner(STRANGER);
        vm.prank(OWNER);
        vm.expectRevert(StepsBranch.InvalidConfiguration.selector);
        ledger.transferOwner(address(0));
        vm.prank(STRANGER);
        vm.expectRevert(StepsBranch.NotPendingOwner.selector);
        ledger.acceptOwner();

        address first = address(0xF1);
        address second = address(0xF2);
        vm.prank(OWNER);
        ledger.transferOwner(first);
        require(ledger.owner() == OWNER, "nominating does not transfer");
        vm.prank(OWNER);
        ledger.transferOwner(second);
        vm.prank(first);
        vm.expectRevert(StepsBranch.NotPendingOwner.selector);
        ledger.acceptOwner();
        vm.prank(second);
        ledger.acceptOwner();
        require(ledger.owner() == second && ledger.pendingOwner() == address(0), "accepted");
        vm.prank(second);
        vm.expectRevert(StepsBranch.NotPendingOwner.selector);
        ledger.acceptOwner();
        vm.prank(OWNER);
        vm.expectRevert(StepsBranch.NotOwner.selector);
        ledger.setPrice(1);
    }

    // ---- payment ----

    /// forge-config: default.fuzz.runs = 512
    function testFuzzMaxPaymentBoundary(uint256 price, uint256 maxPayment) public {
        price = 1 + (price % 50 ether);
        maxPayment = maxPayment % (price * 2 + 1);
        vm.prank(OWNER);
        ledger.setPrice(price);
        uint256 id = ledger.propose(0, bytes32(0), BODY);
        uint256 before = token.balanceOf(address(this));
        if (maxPayment < price) {
            vm.expectRevert(StepsBranch.PriceAboveLimit.selector);
            ledger.fundWithPayment(id, BODY, maxPayment);
            require(token.balanceOf(address(this)) == before && _status(id) == StepsBranch.Status.Draft, "rolled back");
        } else {
            ledger.fundWithPayment(id, BODY, maxPayment);
            require(token.balanceOf(address(this)) == before - price, "exact price, not maxPayment");
            require(token.balanceOf(address(intake)) == price && token.balanceOf(address(ledger)) == 0, "forwarded");
            require(token.allowance(address(ledger), address(intake)) == 0, "approval cleared");
        }
    }

    function testIntakeThatPullsLessIsRejectedAndRolledBack() public {
        ShortPullIntake short = new ShortPullIntake(1);
        StepsBranch l = new StepsBranch(IIntake(address(short)), address(token), PRICE, OWNER);
        token.approve(address(l), type(uint256).max);
        uint256 id = l.propose(0, bytes32(0), BODY);
        uint256 before = token.balanceOf(address(this));
        vm.expectRevert(StepsBranch.PaymentMismatch.selector);
        l.fundWithPayment(id, BODY, PRICE);
        require(token.balanceOf(address(this)) == before && token.balanceOf(address(l)) == 0, "no tokens moved");
        (,,, uint64 pending) = l.branches(0);
        require(pending == 0 && uint8(_statusOf(l, id)) == 0, "reservation rolled back");
    }

    function testIntakeThatPullsNothingIsRejected() public {
        ShortPullIntake none = new ShortPullIntake(type(uint256).max);
        StepsBranch l = new StepsBranch(IIntake(address(none)), address(token), PRICE, OWNER);
        token.approve(address(l), type(uint256).max);
        uint256 id = l.propose(0, bytes32(0), BODY);
        vm.expectRevert(StepsBranch.PaymentMismatch.selector);
        l.fundWithPayment(id, BODY, PRICE);
    }

    function testFeeOnTransferAssetIsRejected() public {
        FeeToken fee = new FeeToken();
        StepsBranch l = new StepsBranch(IIntake(address(intake)), address(fee), PRICE, OWNER);
        fee.mint(address(this), 10 ether);
        fee.approve(address(l), type(uint256).max);
        uint256 id = l.propose(0, bytes32(0), BODY);
        vm.expectRevert(StepsBranch.PaymentMismatch.selector);
        l.fundWithPayment(id, BODY, PRICE);
        require(fee.balanceOf(address(this)) == 10 ether, "fee token rolled back");
    }

    function testSynchronousCallbackFromIntakeIsRefusedByGuard() public {
        EagerIntake eager = new EagerIntake();
        StepsBranch l = new StepsBranch(IIntake(address(eager)), address(token), PRICE, OWNER);
        token.approve(address(l), type(uint256).max);
        uint256 id = l.propose(0, bytes32(0), BODY);
        l.fundWithPayment(id, BODY, PRICE);
        require(!eager.delivered(), "reentrant callback accepted");
        require(uint8(_statusOf(l, id)) == 1 && l.count() == 0, "still pending, no checkpoint");
    }

    function testFundingFailurePaths() public {
        vm.expectRevert(StepsBranch.UnknownProposal.selector);
        ledger.fundWithPayment(0, BODY, PRICE);
        (uint256 id,) = _fund(0);
        vm.expectRevert(StepsBranch.NotDraft.selector);
        ledger.fundWithPayment(id, BODY, PRICE);
        // A second draft on the same head waits for the branch, then funds once the first is refused.
        uint256 second = ledger.propose(0, bytes32(0), BODY);
        vm.expectRevert(StepsBranch.BranchBusy.selector);
        ledger.fundWithPayment(second, BODY, PRICE);
        (,,,,,,, bytes32 req,,) = ledger.proposals(id);
        require(intake.fail(req, 1, "body_refused"), "refusal delivered");
        ledger.fundWithPayment(second, BODY, PRICE);
        require(_status(second) == StepsBranch.Status.Pending, "second funded after refusal");
    }

    function testUnfundedApprovalCannotBeUsedByStranger() public {
        uint256 id = ledger.propose(0, bytes32(0), BODY);
        // The stranger has no tokens and no approval; the proposer's approval is never used for them.
        uint256 before = token.balanceOf(address(this));
        vm.prank(STRANGER);
        vm.expectRevert(StepsBranch.TokenCallFailed.selector);
        ledger.fundWithPayment(id, BODY, PRICE);
        require(token.balanceOf(address(this)) == before, "proposer charged for a stranger");
    }

    // ---- callbacks and expiry ----

    function testCallbacksForDraftOrUnknownIdsRejected() public {
        ledger.propose(0, bytes32(0), BODY);
        vm.prank(address(intake));
        vm.expectRevert(StepsBranch.UnknownRequest.selector);
        ledger.onResult(bytes32(0), keccak256(RESULT), URI);
        vm.prank(address(intake));
        vm.expectRevert(StepsBranch.UnknownRequest.selector);
        ledger.onFailure(bytes32(0), 1, "x", 0, 0, "");
    }

    function testInvalidLateOutcomesRejectedAfterExpiry() public {
        (uint256 id, bytes32 req) = _fund(0);
        vm.warp(block.timestamp + 7 days);
        ledger.expirePending(id);
        vm.prank(address(intake));
        vm.expectRevert(StepsBranch.InvalidFailureStatus.selector);
        ledger.onFailure(req, 0, "x", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(StepsBranch.InvalidFailureStatus.selector);
        ledger.onFailure(req, 3, "x", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(StepsBranch.InvalidRequestId.selector);
        ledger.onResult(req, bytes32(0), URI);
        (bool received,,,,) = _late(id);
        require(!received, "invalid late outcome archived");
    }

    function testExpiryBoundaryAndRepeat() public {
        uint256 start = block.timestamp;
        (uint256 id,) = _fund(0);
        vm.warp(start + 7 days - 1);
        vm.expectRevert(StepsBranch.TooEarly.selector);
        ledger.expirePending(id);
        vm.warp(start + 7 days);
        vm.prank(STRANGER);
        ledger.expirePending(id);
        vm.expectRevert(StepsBranch.NotPending.selector);
        ledger.expirePending(id);
        vm.expectRevert(StepsBranch.UnknownProposal.selector);
        ledger.expirePending(id + 1);
        require(token.balanceOf(address(intake)) == PRICE && token.balanceOf(address(ledger)) == 0, "no refund");
        (bool received, uint8 status,,,) = _late(id);
        require(!received && status == 0, "absent receipt is not success");
        require(ledger.count() == 0, "no checkpoint");
    }

    function testOnTimeOutcomesNeverWriteLateReceipts() public {
        (uint256 a, bytes32 ra) = _fund(0);
        require(intake.deliver(ra, keccak256(RESULT), URI), "success");
        uint64 child = ledger.forkFromOrigin();
        (uint256 b, bytes32 rb) = _fund(child);
        require(intake.fail(rb, 2, "disagreed"), "failure");
        (bool receivedA,,,,) = _late(a);
        (bool receivedB, uint8 statusB,,, bytes32 reasonB) = _late(b);
        require(!receivedA && !receivedB && statusB == 0 && reasonB == 0, "late receipts written on time");
        (,,,,,,,, bytes32 reason,) = ledger.proposals(b);
        require(_status(b) == StepsBranch.Status.Failed && reason == "disagreed", "failure recorded");
    }

    /// Cold path in its own transaction: late success at a nonzero proposal id with the largest
    /// event URI while newer work is pending, then the newer work becomes the first checkpoint.
    function testLateMaxUriSuccessWhileNewerPendingThenFirstCheckpointFromNonzeroProposal() public {
        ledger.propose(0, bytes32(0), BODY); // proposal 0 stays a draft
        (uint256 old, bytes32 oldReq) = _fund(0);
        vm.warp(block.timestamp + 7 days);
        ledger.expirePending(old);
        (uint256 newer, bytes32 newerReq) = _fund(0);
        string memory uri = _uri(2048);
        require(intake.deliver(oldReq, keccak256(RESULT), uri), "late success lost under stipend");
        (bool received, uint8 st, bytes32 rh, bytes32 uh,) = _late(old);
        require(received && st == 0 && rh == keccak256(RESULT) && uh == keccak256(bytes(uri)), "late receipt");
        (bytes32 head, uint64 revision, uint64 headPlusOne, uint64 pending) = _branch(0);
        require(head == 0 && revision == 0 && headPlusOne == 0 && pending == newer + 1, "branch untouched");
        require(_status(old) == StepsBranch.Status.Expired && ledger.count() == 0, "expired stays expired");

        require(intake.deliver(newerReq, keccak256(RESULT), uri), "first checkpoint lost under stipend");
        StepsBranch.CheckpointView memory c = ledger.checkpoint(0);
        require(c.proposalId == newer && c.revision == 1 && c.parent == 0 && c.requestId == newerReq, "checkpoint");
        (head, revision, headPlusOne, pending) = _branch(0);
        require(head == c.digest && revision == 1 && headPlusOne == 1 && pending == 0, "head advanced");
    }

    function testLateRefusalAndFailureWhileNewerPendingUnderStipend() public {
        (uint256 a, bytes32 ra) = _fund(0);
        vm.warp(block.timestamp + 7 days);
        ledger.expirePending(a);
        (uint256 b, bytes32 rb) = _fund(0);
        vm.warp(block.timestamp + 7 days);
        ledger.expirePending(b);
        (uint256 c,) = _fund(0);
        require(intake.fail(rb, 2, "disagreed"), "late failure lost");
        require(intake.fail(ra, 1, "body_refused"), "late refusal lost");
        (bool recA, uint8 stA,,, bytes32 reasonA) = _late(a);
        (bool recB, uint8 stB,,, bytes32 reasonB) = _late(b);
        require(recA && stA == 1 && reasonA == "body_refused", "refusal archived");
        require(recB && stB == 2 && reasonB == "disagreed", "failure archived");
        (,,, uint64 pending) = _branch(0);
        require(pending == c + 1 && _status(c) == StepsBranch.Status.Pending, "newer pending untouched");
        require(_status(a) == StepsBranch.Status.Expired && _status(b) == StepsBranch.Status.Expired, "still expired");
    }

    function testVeryLongUriCommittedUnderStipend() public {
        (, bytes32 req) = _fund(0);
        string memory uri = _uri(32 * 1024);
        require(intake.deliver(req, keccak256(RESULT), uri), "32 KiB uri callback lost");
        require(ledger.checkpoint(0).uriHash == keccak256(bytes(uri)), "uri committed by hash");
    }

    // ---- forks and snapshots ----

    function testForkAndSnapshotFailurePaths() public {
        vm.expectRevert(StepsBranch.UnknownCheckpoint.selector);
        ledger.fork(0);
        vm.expectRevert(StepsBranch.UnknownCheckpoint.selector);
        ledger.forkWithSnapshot(0, RESULT);
        vm.expectRevert(StepsBranch.UnknownCheckpoint.selector);
        ledger.checkpoint(0);
        vm.expectRevert(StepsBranch.UnknownBranch.selector);
        ledger.snapshotOf(1);
        vm.expectRevert(StepsBranch.UnknownBranch.selector);
        ledger.propose(1, bytes32(0), BODY);

        (, bytes32 req) = _fund(0);
        require(intake.deliver(req, keccak256(RESULT), URI), "success");
        vm.expectRevert(StepsBranch.SnapshotMismatch.selector);
        ledger.forkWithSnapshot(0, "");
        vm.expectRevert(StepsBranch.SnapshotMismatch.selector);
        ledger.forkWithSnapshot(0, bytes.concat(RESULT, "\n"));
        require(ledger.branchCount() == 1, "no branch from a failed fork");
    }

    function testOversizedExactSnapshotRejectedButReferenceForkWorks() public {
        bytes memory big = new bytes(4097);
        for (uint256 i; i < big.length; ++i) {
            big[i] = "x";
        }
        (, bytes32 req) = _fund(0);
        require(intake.deliver(req, keccak256(big), URI), "success");
        vm.expectRevert(StepsBranch.SnapshotTooLarge.selector);
        ledger.forkWithSnapshot(0, big);
        uint64 child = ledger.fork(0);
        require(ledger.snapshotOf(child).length == 0, "reference fork stores nothing");
    }

    function testForkCheckpointIsIndependentAndDigestDiffersPerBranch() public {
        (, bytes32 r0) = _fund(0);
        require(intake.deliver(r0, keccak256(RESULT), URI), "first");
        StepsBranch.CheckpointView memory base = ledger.checkpoint(0);
        uint64 a = ledger.forkWithSnapshot(0, RESULT);
        uint64 b = ledger.fork(0);
        _checkForkHead(a, base.digest);
        require(ledger.count() == 1, "fork is not a successful step");
        (, bytes32 ra) = _fund(a);
        (, bytes32 rb) = _fund(b);
        (, bytes32 r0b) = _fund(0);
        // Same result on three branches: each advances only its own head with a distinct digest.
        require(intake.deliver(rb, keccak256(RESULT), URI), "b");
        require(intake.deliver(ra, keccak256(RESULT), URI), "a");
        StepsBranch.CheckpointView memory cb = ledger.checkpoint(1);
        StepsBranch.CheckpointView memory ca = ledger.checkpoint(2);
        require(cb.branchId == b && ca.branchId == a && cb.requestId == rb && ca.requestId == ra, "owners");
        require(ca.digest != cb.digest && ca.revision == 2 && cb.revision == 2, "independent revisions");
        require(ca.parent == base.digest && cb.parent == base.digest, "same parent");
        _checkForkHead(0, base.digest);
        require(intake.deliver(r0b, keccak256(RESULT), URI), "source");
        require(ledger.checkpoint(3).digest != ca.digest, "source digest distinct");
        require(keccak256(ledger.snapshotOf(a)) == keccak256(RESULT) && ledger.snapshotOf(b).length == 0, "snapshots");
    }

    function _checkForkHead(uint64 branchId, bytes32 digest) internal view {
        (bytes32 h, uint64 rev, uint64 hp,) = _branch(branchId);
        require(h == digest && rev == 1 && hp == 1, "branch head is the shared checkpoint");
    }

    function _statusOf(StepsBranch l, uint256 id) internal view returns (StepsBranch.Status s) {
        (,, s,,,,,,,) = l.proposals(id);
    }
}
