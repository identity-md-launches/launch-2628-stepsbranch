// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StepsBranch, IIntake} from "../src/StepsBranch.sol";
import {MockToken} from "../src/MockToken.sol";
import {DocumentedIntake} from "./StepsBranch.t.sol";

interface AuditVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function prank(address) external;
    function expectRevert(bytes4) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// Reproductions of the two findings of the import audit (see ADAPTATION.md).
/// Both describe the supplied design, which the brief requires to be preserved; these tests
/// pin that behaviour so a later change to it is visible.
contract AuditFindingsTest {
    AuditVm private constant vm = AuditVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes internal constant VICTIM_BODY = '{"objective":"Victim step","skill":"research-report"}';
    bytes internal constant ATTACKER_BODY = '{"objective":"Attacker step","skill":"research-report"}';
    uint256 internal constant PRICE = 0.5 ether;
    address internal constant VICTIM = address(0xA11CE);
    address internal constant ATTACKER = address(0xBAD);

    StepsBranch internal ledger;
    DocumentedIntake internal intake;
    MockToken internal token;

    function setUp() public {
        token = new MockToken();
        intake = new DocumentedIntake();
        ledger = new StepsBranch(IIntake(address(intake)), address(token), PRICE, address(this));
        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? VICTIM : ATTACKER;
            token.mint(who, 10 ether);
            vm.prank(who);
            token.approve(address(ledger), type(uint256).max);
        }
    }

    function _head(uint64 id) internal view returns (bytes32 h) {
        (h,,,) = ledger.branches(id);
    }

    /// Finding 2ba0657b (low): reproduces. Branches have no creator, so anyone who pays can hold a
    /// branch's single pending slot and append its own checkpoint, leaving other Drafts stale.
    /// Not fixed: the brief forbids adding authority. The victim loses no funds and can fork away.
    function testAuditFindingSharedBranchCanBeTakenWithoutVictimLoss() public {
        vm.prank(VICTIM);
        uint64 b = ledger.forkFromOrigin();
        vm.prank(VICTIM);
        uint256 vid = ledger.propose(b, bytes32(0), VICTIM_BODY);

        vm.prank(ATTACKER);
        uint256 aid = ledger.propose(b, bytes32(0), ATTACKER_BODY);
        vm.prank(ATTACKER);
        bytes32 rid = ledger.fundWithPayment(aid, ATTACKER_BODY, PRICE);

        vm.prank(VICTIM);
        vm.expectRevert(StepsBranch.BranchBusy.selector);
        ledger.fundWithPayment(vid, VICTIM_BODY, PRICE);
        require(token.balanceOf(VICTIM) == 10 ether, "victim charged while busy");

        require(intake.deliver(rid, keccak256("r"), "ipfs://x/result.json"), "attacker callback");
        require(
            _head(b) == ledger.checkpoint(0).digest && ledger.checkpoint(0).proposalId == aid, "attacker step not head"
        );

        vm.prank(VICTIM);
        vm.expectRevert(StepsBranch.StaleAnchor.selector);
        ledger.fundWithPayment(vid, VICTIM_BODY, PRICE);
        require(token.balanceOf(VICTIM) == 10 ether, "victim charged for stale draft");

        // The documented escape: an independent branch the attacker's pending work cannot touch.
        vm.prank(VICTIM);
        uint64 own = ledger.forkFromOrigin();
        vm.prank(VICTIM);
        uint256 vid2 = ledger.propose(own, bytes32(0), VICTIM_BODY);
        vm.prank(VICTIM);
        ledger.fundWithPayment(vid2, VICTIM_BODY, PRICE);
        require(token.balanceOf(VICTIM) == 10 ether - PRICE, "victim pays exactly once");
    }

    /// Finding 561bdcd1 (info): reproduces as a dependency, not a defect. The heaviest success path
    /// (first checkpoint, nonzero proposal id, 2048-byte URI) fits the Intake's 200000-gas stipend.
    /// The cold-transaction figure is measured by sdk/local-integration.mjs on Anvil.
    function testAuditFindingHeaviestFirstCheckpointFitsStipend() public {
        token.mint(address(this), 1 ether);
        token.approve(address(ledger), type(uint256).max);
        bytes memory body = VICTIM_BODY;
        ledger.propose(0, bytes32(0), body);
        ledger.propose(0, bytes32(0), body);
        bytes32 rid = ledger.fundWithPayment(1, body, PRICE);
        bytes memory uri = new bytes(2048);
        for (uint256 i; i < uri.length; i++) {
            uri[i] = "a";
        }
        vm.recordLogs();
        require(intake.deliver(rid, keccak256("result"), string(uri)), "heaviest callback not delivered");
        AuditVm.Log[] memory logs = vm.getRecordedLogs();
        uint256 callGas;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(intake)) (,, callGas) = abi.decode(logs[i].data, (uint8, bool, uint256));
        }
        require(callGas > 0 && callGas < 200_000, "stipend exceeded");
        require(
            ledger.count() == 1 && ledger.checkpoint(0).proposalId == 1 && ledger.checkpoint(0).revision == 1,
            "first checkpoint"
        );
    }
}
