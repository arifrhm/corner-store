# OP Stack L2 Operational Semantics

## 개요 / 범위

이 문서는 Corner Store를 OP Stack 기반 L2에 배포할 때의 트랜잭션 확정 단계, 출금
챌린지 기간, forced inclusion escape hatch, fault proof 상태 확인 방법을 정리하고,
이 사실들이 우리 코드의 confirmation 처리와 어떻게 다른지 기록한다.

여기 적힌 내용은 OP Stack 공통 설계에 대한 설명이다. block time, batch 제출 지연,
L1 contract 주소, fault proof 설정은 체인마다 다르므로 배포 대상 체인에서 다음
방법으로 직접 확인한다.

- 대상 체인 public RPC에 대한 live JSON-RPC 호출
  (`eth_getBlockByNumber` with `latest`/`safe`/`finalized`, `optimism_syncStatus`)
- L1에 배포된 대상 체인의 `OptimismPortal`, `SystemConfig`, `DisputeGameFactory`에
  대한 `cast` on-chain read
- 대상 체인 운영자가 공개한 rollup config

확인할 항목은 마지막 절 "대상 체인별 확인 항목"에 모아 두었다. 각 절에서 OP Stack
공통 사실인지, 대상 체인에서 확인해야 하는 값인지, 우리 추론인지를 구분해 표기한다.

## 트랜잭션 확정 단계

OP Stack execution client는 `latest`, `safe`, `finalized` block tag를 지원한다.
`safe`와 `finalized`가 `latest`보다 얼마나 뒤처지는지는 batch 제출 주기와 L1
finality에 따라 체인마다 다르다. 대상 체인이 batch 제출 주기에 대한 공식 SLA를
게시하지 않았다면, RPC로 관측한 지연은 **관측된 범위이지 SLA가 아니다.**

| 단계 | 의미 | 지연 | 되돌릴 수 있는 주체 | RPC 확인 방법 |
| --- | --- | --- | --- | --- |
| `latest` (unsafe) | sequencer가 만들었지만 아직 L1에 batch로 올라가지 않은 상태. OP Stack L2에는 일반적으로 public mempool이 없고 sequencer가 단독으로 순서를 정하므로, sequencer가 재정렬/폐기할 수 있다. | block time 수준 | sequencer 단독 | `eth_getBlockByNumber("latest", false)` |
| `safe` | batch data가 L1에 제출되어 L1 데이터로부터 derive 가능한 상태. 되돌리려면 깊은 L1 reorg가 필요하다. | batch 제출 주기에 따라 다름 | 깊은 L1 reorg (사실상 sequencer 단독으로는 불가) | `eth_getBlockByNumber("safe", false)` |
| `finalized` | batch를 담은 L1 block 자체가 Ethereum consensus에서 finalize된 상태 (2 epoch). 사실상 되돌릴 수 없다. | `safe` 이후 L1 finality까지 추가 대기 | 사실상 불가 | `eth_getBlockByNumber("finalized", false)` |

`optimism_syncStatus`는 op-node 전용 method이지 execution layer `eth_*` method가
아니므로, public RPC에서는 whitelist되지 않는 경우가 많다
(`rpc method is not whitelisted` 응답). dApp은 위 세 tag에 대한
`eth_getBlockByNumber` 호출만으로 확정 단계를 판단해야 한다.

**중요한 구분 (OP Stack 공식 문서 인용):** "Fault proofs do not impact the
finalization of the L2 rollup, only the finalization of withdrawal transactions
to the L1." (https://docs.optimism.io/stack/differences) 즉 위 `finalized` tag가
가리키는 L2 상태 확정성과, 아래 "출금 챌린지 기간"에서 다루는 출금 대기는 서로
다른 질문이다. 거래 영수증에 "결제 최종 확정"을 표시할 때 이 둘을 절대 혼용하면
안 된다.

## 영수증 화면 권고

3단계 상태 모델을 권고한다.

1. **접수** (기준: `latest`) - 제출 직후, block time 수준. UX 반응성 목적으로만
   사용하고 "확정"으로 표시하지 않는다.
2. **확정** (기준: `safe`) - batch 제출 주기에 따라 지연된다. batch가 L1에 올라가
   L1 데이터로부터 derive 가능한 상태.
3. **최종** (기준: `finalized`) - `safe` 이후 L1 finality까지 추가로 기다린다.
   여기가 "settlement final" 타임스탬프를 찍어야 할 유일한 지점이다. 단, 이는 L2
   rollup finality이며 L2->L1 출금 자체의 최종성과는 다르다 (출금은 별도의
   challenge window를 거친다, 아래 참조).

트랜잭션이 속한 block number를 `safe`/`finalized` block number와 비교하는 방식의
TypeScript 예시:

```ts
type Stage = "접수" | "확정" | "최종";

async function getReceiptStage(
  rpcUrl: string,
  txBlockNumber: bigint,
): Promise<Stage> {
  const [safeBlock, finalizedBlock] = await Promise.all([
    getBlockByTag(rpcUrl, "safe"),
    getBlockByTag(rpcUrl, "finalized"),
  ]);

  if (txBlockNumber <= finalizedBlock.number) return "최종";
  if (txBlockNumber <= safeBlock.number) return "확정";
  return "접수";
}

async function getBlockByTag(rpcUrl: string, tag: "safe" | "finalized") {
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_getBlockByNumber",
      params: [tag, false],
    }),
  });
  const { result } = await res.json();
  return { number: BigInt(result.number), timestamp: BigInt(result.timestamp) };
}
```

## 출금 챌린지 기간

이 절은 "트랜잭션 확정 단계"와 별개 주제다. **L2 상태가 `finalized`라고 해서
L2->L1 출금이 즉시 인출 가능한 것은 아니다.** 이 구분을 영수증/UI 문구에서 절대
혼동하지 않는다.

출금 대기 기간은 대상 체인이 L1에 배포한 `OptimismPortal`에서 직접 읽는다.

- `proofMaturityDelaySeconds()`: 출금 증명 후 finalize까지의 대기. OP Stack
  기본값은 604800 = 7일이다.
- `disputeGameFinalityDelaySeconds()`: dispute game 해소 후 출금 finalize 전까지의
  추가 대기.
- 이 지연은 오직 L2->L1 출금에만 적용되며, L1->L2 예치나 일반 L2 상태 확정과는
  무관하다.

## Escape hatch / 강제 포함

forced inclusion은 OP Stack 공통 설계다. 대상 체인에서는 L1에 `OptimismPortal`이
배포되어 있는지로 경로 존재를 확인한다.

- **메커니즘**: 대상 체인의 L1 `OptimismPortal`에서 `depositTransaction()`을
  직접 호출한다. derivation pipeline은 sequencing window (대상 체인 rollup
  config의 `seq_window_size`, L1 block 단위)가 지나면 늦어도 그 시점까지는 이
  트랜잭션을 포함해야 한다.
- **address aliasing 주의 (우리 계약에 중요)**: L2에서 이 호출은 원래 L1
  주소가 아니라 `L1 address + 0x1111000000000000000000000000000000001111`로
  계산된 **aliased 주소**로부터 실행된다. 즉 L2에서 EOA가 보유한 operator/owner
  role은, 그 aliased 주소가 별도로 authorize되어 있지 않은 한 forced path를 통해
  자동으로 행사되지 않는다.
- **강제할 수 있는 것**: ETH transfer, aliased 계정으로부터의 임의 contract call.
- **강제할 수 없는 것**: 다른 대기 중인 L2 트랜잭션과의 순서 관계 (삽입할 L2
  mempool 자체가 없음), 다른 당사자의 미확정 트랜잭션과의 atomicity, L2 block
  gas limit을 초과하는 작업, 이미 sequencing된 트랜잭션의 취소/재정렬.

## Fault proof 상태와 잔여 중앙화 위험

대상 체인의 fault proof 상태는 L1 contract에서 다음 값을 읽어 확인한다.

- `DisputeGameFactory.gameImpls(0)` (permissionless CANNON): zero address면
  permissionless fault-proof game이 배포되어 있지 않다.
- `DisputeGameFactory.gameImpls(1)` (PERMISSIONED_CANNON): permissioned game
  구현 주소.
- `OptimismPortal.respectedGameType()`: portal이 출금 증명으로 인정하는 game
  type. `1`이면 portal은 오직 permissioned game이 제출한 출금 증명만 인정한다.

**우리 분석 (체인 운영자의 공식 표명이 아님)**: `gameImpls(0)`이 zero address이고
`respectedGameType()`이 `1`인 체인은 fault-proof 대응 가능한 contract를
permissioned-only 모드로 운영 중이며, 사실상 Stage 0 (centralized sequencer +
permissioned proposer/challenger)에 해당한다. 공식 stage label을 게시하지 않는
체인이라면 이 판단은 우리 분석으로 표기한다.

**운영상 함의 (permissioned-only 체인)**: forced inclusion은 sequencer가 죽어도
L1->L2 예치/호출 경로를 살려두지만, L2->L1 출금은 여전히 단일 permissioned
proposer/challenger keypair에 의존한다. 이 키가 유실되면 출금을 permissionless하게
증명하고 finalize할 경로가 없다. 이는 sequencer censorship과는 별개의, 실질적인
잔여 중앙화 위험이다.

## 현재 코드와의 차이

- `blockTag`를 지정한 코드가 저장소 전체에서 0건이다 (`grep -rn "blockTag"`).
  모든 block read가 암묵적으로 `"latest"`를 사용한다.
- `services/testnet-rfq-demo/public/app.js:127,142`의 현재 영수증 UI는
  "Submitted {hash}" 다음 `transaction.wait()` (ethers 기본값 1 confirmation) 후
  "Confirmed in block {n}"만 보여준다. timestamp, finality 상태, tx explorer
  link가 없다.
- `services/rfq/src/coordinator.ts:225`의 `DEFAULT_CONFIRMATIONS = 12`와
  `PUBLISHED -> FILL_OBSERVED -> FILLED` state machine은 confirmation depth로
  게이팅된다.
- `services/operator-api/src/indexer.ts:16-42`의 `FinalityAwareIndexer`는
  `head - confirmations` (기본 12)를 사용해 `{lastFinalizedBlock,
  lastFinalizedHash}` cursor를 저장한다. 다만 실행 중인 서버
  (`src/index.ts`)에서는 인스턴스화되지 않고 `test/smoke.ts`에서만 쓰인다.

**핵심 지적**: 고정된 12-confirmation depth 휴리스틱은 L1 mental model이며 OP
Stack L2에는 맞지 않는다. 예를 들어 block time이 1초인 체인에서 12 confirmation은
약 12초에 불과해 `safe`보다 훨씬 약하고, 애초에 L2 block depth는 어떤
reorg-resistance 경계에도 대응하지 않는다. L2 되돌림은 sequencer의 행동과 L1
reorg에 의해 결정되지, L2 block depth에 의해 결정되지 않기 때문이다. 올바른 신호는
`safe`/`finalized` tag다. 이는 production에서 이미 깨져 있는 문제가 아니라
(해당 indexer는 서버에 연결되어 있지 않다), **권고 사항이자 gap**으로 다룬다.

## 대상 체인별 확인 항목

배포 대상 체인마다 다음을 확인하고, 각 값의 출처 (공식 문서, on-chain 직접 조회,
우리 추론)를 함께 기록한다.

- [ ] block time
- [ ] block gas limit
- [ ] batch 제출 SLA 공표 여부. 없으면 `safe`/`finalized` 지연은 관측 범위로만
  표기한다.
- [ ] 공식 decentralization stage label 게시 여부. 없으면 위 fault proof 조회
  결과에 기반한 우리 분석으로 표기한다.
- [ ] L1 contract 주소 (`OptimismPortal`, `SystemConfig`, `L1CrossDomainMessenger`,
  `L1StandardBridge`, `DisputeGameFactory`, `batchInbox`)와 공식 문서 게시 여부
- [ ] public RPC method whitelist (`safe`/`finalized` tag 지원,
  `optimism_syncStatus` 허용 여부)
- [ ] rollup config의 `seq_window_size`와 `OptimismPortal`의 출금 지연 값
