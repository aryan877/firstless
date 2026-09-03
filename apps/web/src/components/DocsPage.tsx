import ArrowLeft from "lucide-react/dist/esm/icons/arrow-left.mjs";
import ArrowRight from "lucide-react/dist/esm/icons/arrow-right.mjs";
import ArrowUpRight from "lucide-react/dist/esm/icons/arrow-up-right.mjs";
import Check from "lucide-react/dist/esm/icons/check.mjs";
import { Brand } from "@/components/Brand";
import deployment from "../../public/deployments/unichain-sepolia.json";

type DocsPageProps = { onOpenStory: () => void; onOpenDashboard: () => void };

const contracts = [
  ["FirstlessHook", deployment.hook], ["FirstlessRouter", deployment.router],
  ["RefundRedeemer", deployment.redeemer], [deployment.token0Symbol, deployment.token0], [deployment.token1Symbol, deployment.token1],
] as const;

const section = "px-[6vw] py-24 max-[700px]:px-[1.1rem] max-[700px]:py-20";
const title = "mt-3 max-w-[17ch] text-[clamp(3rem,5.5vw,6.3rem)] font-[550] leading-[.92] tracking-[-.07em] max-[700px]:text-[clamp(2.8rem,13.5vw,4.1rem)]";
const mono = "font-mono text-[.65rem] leading-relaxed text-[#666962]";

function shortAddress(address: string) { return `${address.slice(0, 8)}…${address.slice(-6)}`; }

function Heading({ number, eyebrow, children, id, light = false }: { number: string; eyebrow: string; children: string; id: string; light?: boolean }) {
  return <div className="mb-16 grid grid-cols-[4rem_minmax(0,1fr)] items-start gap-4 max-[700px]:mb-10 max-[700px]:grid-cols-[2rem_1fr] max-[700px]:gap-1">
    <span className={`pt-1 font-mono text-[.7rem] ${light ? "text-[#aab0a7]" : "text-[#a95638]"}`}>{number}</span>
    <div><p className={`${mono} ${light ? "!text-[#aab0a7]" : ""}`}>{eyebrow}</p><h2 id={id} className={title}>{children}</h2></div>
  </div>;
}

export function DocsPage({ onOpenStory, onOpenDashboard }: DocsPageProps) {
  return <main id="top" className="min-h-svh overflow-x-clip bg-[#f1f0ea] text-[#171815]">
    <header className="sticky top-0 z-20 grid min-h-20 grid-cols-[1fr_auto_1fr] items-center border-b border-black/10 bg-[#f1f0ea]/90 px-[4vw] py-3 backdrop-blur-xl max-[1050px]:grid-cols-[1fr_auto] max-[700px]:min-h-18 max-[700px]:px-4">
      <Brand />
      <nav className="flex gap-7 text-xs text-[#666962] max-[1050px]:hidden" aria-label="Documentation sections">
        <a className="hover:text-[#171815]" href="#trade">the trade</a><a className="hover:text-[#171815]" href="#clearing">clearing</a><a className="hover:text-[#171815]" href="#contracts">contracts</a><a className="hover:text-[#171815]" href="#evidence">tests</a><a className="hover:text-[#171815]" href="#limits">limits</a>
      </nav>
      <div className="flex justify-self-end gap-2">
        <button type="button" className="inline-flex min-h-11 items-center gap-2 rounded-full border border-black/15 bg-white/60 px-4 text-xs font-semibold max-[700px]:hidden" onClick={onOpenStory}><ArrowLeft className="size-4" aria-hidden="true" /> story</button>
        <button type="button" className="inline-flex min-h-11 items-center gap-2 rounded-full bg-[#171815] px-4 text-xs font-semibold text-[#fbfaf6] max-[700px]:min-h-10 max-[700px]:px-3" onClick={onOpenDashboard}>dashboard <ArrowUpRight className="size-4" aria-hidden="true" /></button>
      </div>
    </header>

    <section className="grid min-h-[calc(100svh-5rem)] grid-cols-[minmax(0,.92fr)_minmax(32rem,1.08fr)] items-end gap-[6vw] bg-[radial-gradient(circle_at_78%_48%,rgba(40,82,162,.12),transparent_27rem),radial-gradient(circle_at_22%_76%,rgba(169,86,56,.12),transparent_30rem)] px-[6vw] py-24 max-[1050px]:min-h-0 max-[1050px]:grid-cols-1 max-[700px]:block max-[700px]:px-[1.1rem] max-[700px]:py-16" aria-labelledby="docs-title">
      <div><p className="mb-6 font-mono text-[.65rem] text-[#a95638]">Firstless documentation</p><h1 id="docs-title" className="max-w-[11ch] text-[clamp(4rem,8vw,8.8rem)] font-[580] leading-[.86] tracking-[-.08em] max-[700px]:text-[clamp(3.6rem,16vw,5.1rem)]">One exact trade.<br />Two moments.</h1><span className="mt-8 block max-w-[38rem] text-[clamp(1.15rem,1.7vw,1.55rem)] leading-[1.45] tracking-[-.025em] text-[#444741] max-[700px]:text-base">Alice receives her tokens inside the signed transaction. Her final bill waits until every opted-in order from that pool and canonical block is known.</span></div>
      <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-4 rounded-[2rem] bg-[#fbfaf6]/80 p-6 shadow-[0_30px_80px_rgba(23,24,21,.09)] max-[1050px]:max-w-[52rem] max-[700px]:mt-10 max-[700px]:grid-cols-1 max-[700px]:rounded-2xl max-[700px]:p-3" aria-label="Firstless example trade">
        {[['Alice asks for', '10', 'fETH', 'delivered immediately', 'bg-[#e8edf7]'], ['After the block', '10.338168', 'fUSD', 'final bill', 'bg-[#e2e8df]']].map(([label, value, unit, note, tone], index) => <div key={label} className={`grid min-h-48 content-end gap-1 rounded-[1.4rem] p-5 max-[700px]:min-h-36 ${tone}`} style={{ order: index * 2 }}><small className={mono}>{label}</small><strong className="text-[clamp(2rem,4vw,4rem)] font-[570] leading-none tracking-[-.065em]">{value}<i className="mt-2 block font-mono text-[.28em] not-italic tracking-normal text-[#2852a2]">{unit}</i></strong><span className={mono}>{note}</span></div>)}
        <b className="text-3xl font-normal text-[#8b8e87] max-[700px]:rotate-90 max-[700px]:text-center" style={{ order: 1 }} aria-hidden="true">→</b>
      </div>
    </section>

    <section id="trade" className={`${section} bg-[#dedfd7]`} aria-labelledby="trade-title">
      <Heading number="01" eyebrow="Start with the user" id="trade-title">What happens to Alice’s order?</Heading>
      <ol className="ml-auto grid max-w-[86rem] list-none p-0">{[
        ["She chooses an exact output.", "Alice wants exactly 10 fETH. fETH and fUSD are valueless test tokens in this deployment."],
        ["She signs a maximum, not a price.", "In one recorded Unichain run, the maximum was 12.494024 fUSD. The signature also binds the payer, pool, recipient, nonce, deadline, block window, and call plan."],
        ["The output arrives in that transaction.", "The router collects the maximum and the hook sends 10 fETH before the call ends. Another contract can use that output immediately."],
        ["The block decides the final bill.", "Once the set closes, Firstless calculates Alice’s marginal bill and backs the unused fUSD as a refund."],
      ].map(([itemTitle, body], index) => <li className="grid grid-cols-[4rem_minmax(0,1fr)] gap-6 border-t border-black/15 py-9 max-[700px]:grid-cols-[2.7rem_1fr] max-[700px]:gap-3 max-[700px]:py-6" key={itemTitle}><span className="grid size-11 place-items-center rounded-full bg-[#171815] font-mono text-[.65rem] text-[#fbfaf6]">{index + 1}</span><div className="grid grid-cols-[minmax(16rem,.75fr)_minmax(0,1.25fr)] items-baseline gap-12 max-[700px]:grid-cols-1 max-[700px]:gap-2"><strong className="text-[clamp(1.5rem,2.5vw,2.6rem)] font-[570] tracking-[-.045em] max-[700px]:text-[1.35rem]">{itemTitle}</strong><p className="max-w-[45rem] text-base leading-relaxed text-[#666962] max-[700px]:text-sm">{body}</p></div></li>)}</ol>
    </section>

    <section id="clearing" className={`${section} bg-[#fbfaf6]`} aria-labelledby="clearing-title">
      <Heading number="02" eyebrow="Same pool, same block" id="clearing-title">Opposite trades meet before the curve.</Heading>
      <div className="mx-auto grid max-w-[96rem] grid-cols-[minmax(20rem,.9fr)_minmax(22rem,1fr)_3rem_minmax(12rem,.55fr)] items-stretch gap-4 max-[1050px]:grid-cols-2 max-[700px]:grid-cols-1" role="img" aria-label="Eve buys 100 fETH, Alice buys 10 fETH, and Eve sells 100 fETH in one block. Eve's opposite trades net and Alice's 10 fETH residual reaches the curve.">
        <div className="grid gap-2">{[["Eve buys", "100 fETH", false], ["Alice buys", "10 fETH", true], ["Eve sells", "100 fETH", false]].map(([label, value, alice]) => <div key={`${label}-${value}`} className={`grid min-h-18 grid-cols-[1rem_minmax(0,1fr)_auto_auto] items-center gap-3 rounded-2xl px-4 py-3 max-[700px]:grid-cols-[.8rem_minmax(0,1fr)_auto] ${alice ? "bg-[#e8edf7]" : "bg-[#f7e9e3]"}`}><i className={`size-3 rounded-full ${alice ? "bg-[#2852a2]" : "bg-[#a95638]"}`} /><span>{label as string}</span><strong className="whitespace-nowrap">{value as string}</strong><b className="text-xl font-normal text-[#666962] max-[700px]:hidden">{label === "Eve sells" ? "←" : "→"}</b></div>)}</div>
        <div className="grid content-center justify-items-start gap-1 rounded-[1.6rem] border border-[#8d9a89] bg-[#e0e7de] p-6"><small className={mono}>one canonical-block set</small><strong className="my-2 font-mono text-[clamp(2rem,4vw,4rem)] font-normal tracking-[-.06em]">100 ↔ 100</strong><span className={mono}>opposing flow nets at the opening reserve ratio</span></div>
        <ArrowRight className="w-10 self-center text-[#979a93] max-[1050px]:hidden" aria-hidden="true" />
        <div className="grid content-center justify-items-start gap-1 rounded-[1.6rem] border border-[#4265ac] bg-[#e8edf7] p-6 text-[#234c9b] max-[1050px]:col-start-2 max-[700px]:col-auto"><small className={mono}>curve receives</small><strong className="my-2 text-3xl tracking-[-.05em]">10 fETH</strong><span className={mono}>Alice’s residual</span></div>
      </div>
      <p className="ml-auto mt-10 max-w-[62rem] text-[1.05rem] leading-relaxed text-[#666962]">Firstless does not label Eve as an attacker or give Alice a special place in line. Every supported order follows the same calculation after the set is complete.</p>
    </section>

    <section className={`${section} bg-[#e9e8e1]`} aria-labelledby="math-title">
      <Heading number="03" eyebrow="Leave one order out" id="math-title">Alice pays the cost her order added.</Heading>
      <div className="grid grid-cols-[1fr_auto_1fr_auto_.8fr_auto_1fr] items-stretch gap-2 max-[700px]:grid-cols-1" aria-label="Alice's final bill equals complete-set cost minus the same set without Alice plus a rounding buffer">
        {[['cost of', 'Eve + Alice + Eve'], ['−', ''], ['cost of', 'Eve + Eve'], ['+', ''], ['bounded', 'rounding buffer'], ['=', ''], ['Alice’s final bill', '10.338168 fUSD']].map(([label, value], index) => value ? <div key={`${label}-${value}`} className={`grid min-h-40 min-w-0 content-end gap-2 rounded-[1.4rem] p-5 max-[700px]:min-h-24 ${index === 6 ? "bg-[#cdd8ca] text-[#243229]" : "bg-[#fbfaf6]"}`}><span className={mono}>{label}</span><strong className="text-[clamp(1.3rem,2.1vw,2.2rem)] font-[570] tracking-[-.04em]">{value}</strong></div> : <b key={`${label}-${index}`} className="grid place-items-center font-mono text-xl font-normal text-[#8b8e87] max-[700px]:min-h-6">{label}</b>)}
      </div>
      <div className="mt-4 grid grid-cols-[1fr_auto_1fr_auto_1fr] items-stretch gap-3 rounded-[1.6rem] bg-[#1d1f1b] p-4 text-[#ecece5] max-[700px]:grid-cols-1" aria-label="12.494024 fUSD maximum minus 10.338168 fUSD final bill equals 2.155857 fUSD refund">
        {[['maximum held', '12.494024'], ['−', ''], ['final bill', '10.338168'], ['=', ''], ['refund', '2.155857']].map(([label, value], index) => value ? <div key={label} className={`grid min-h-32 content-center gap-1 p-4 max-[700px]:min-h-20 ${index === 4 ? "rounded-2xl bg-[#aebdaa] text-[#1d2920]" : ""}`}><span className={`${mono} ${index === 4 ? "!text-[#526154]" : "!text-[#9ca098]"}`}>{label}</span><strong className="font-mono text-[clamp(1.4rem,2.5vw,2.7rem)] font-normal tracking-[-.06em]">{value} <small className="text-[.36em] tracking-normal text-[#9ca098]">fUSD</small></strong></div> : <b key={`${label}-${index}`} className="grid place-items-center font-mono text-xl font-normal text-[#8b8e87] max-[700px]:min-h-6">{label}</b>)}
      </div>
    </section>

    <section id="contracts" className={`${section} bg-[#1b1d19] text-[#f2f1eb]`} aria-labelledby="contracts-title">
      <Heading number="04" eyebrow="The onchain path" id="contracts-title" light>How the transaction moves through Uniswap v4.</Heading>
      <div className="grid grid-cols-[repeat(7,auto)] items-center gap-2 max-[1050px]:grid-cols-2 max-[700px]:grid-cols-1">{[
        ["FirstlessRouter", "Checks Alice’s signature", "It verifies the nonce, time and block limits, pool, amounts, recipient, and optional downstream call."],
        ["PoolManager.unlock", "Moves value atomically", "The maximum enters custody and the exact output leaves during the same transaction."],
        ["FirstlessHook", "Records the block set", "Custom accounting keeps reserves, escrow, fees, pending deposits, and refund liabilities in separate buckets."],
        ["RefundRedeemer", "Returns unused input", "A backed PoolManager ERC-6909 claim becomes the underlying ERC-20 when Alice redeems it."],
      ].flatMap(([name, itemTitle, body], index, all) => [<article key={name} className="grid min-h-80 min-w-0 content-start gap-3 rounded-3xl border border-white/10 bg-[#252722] p-6 max-[1050px]:min-h-64 max-[700px]:min-h-56"><span className="mb-auto grid size-9 place-items-center rounded-full bg-[#afbeac] font-mono text-[.6rem] text-[#1e211d]">{index + 1}</span><small className="font-mono text-[.6rem] text-[#9aa499]">{name}</small><strong className="text-[clamp(1.25rem,1.8vw,1.9rem)] font-[560] leading-tight tracking-[-.04em]">{itemTitle}</strong><p className="text-[.82rem] leading-relaxed text-[#a7aaa2]">{body}</p></article>, ...(index < all.length - 1 ? [<i key={`arrow-${index}`} className="text-xl not-italic text-[#747871] max-[1050px]:hidden" aria-hidden="true">→</i>] : [])])}</div>
      <p className="mt-6 font-mono text-[.65rem] leading-relaxed text-[#a7aaa2]">Read the official Uniswap v4 <a className="text-[#d8ded5] underline underline-offset-3" href="https://developers.uniswap.org/docs/protocols/v4/concepts/hooks" target="_blank" rel="noreferrer">hooks overview</a>, <a className="text-[#d8ded5] underline underline-offset-3" href="https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting" target="_blank" rel="noreferrer">custom-accounting guide</a>, and <a className="text-[#d8ded5] underline underline-offset-3" href="https://developers.uniswap.org/docs/protocols/v4/security" target="_blank" rel="noreferrer">security guidance</a>.</p>
    </section>

    <section id="evidence" className={`${section} bg-[#d8dad2]`} aria-labelledby="evidence-title">
      <Heading number="05" eyebrow="Reproducible checks" id="evidence-title">What we tested.</Heading>
      <div className="grid grid-cols-[.7fr_1.3fr] items-end gap-[5vw] border-b border-black/15 pb-12 max-[700px]:grid-cols-1 max-[700px]:gap-8"><strong className="text-[clamp(6rem,15vw,15rem)] font-[540] leading-[.72] tracking-[-.1em] text-[#2852a2] max-[700px]:text-[7.5rem]">37 → 0</strong><p className="max-w-[44rem] text-[clamp(1.35rem,2.2vw,2.2rem)] leading-snug tracking-[-.03em] text-[#474a44] max-[700px]:text-xl">Thirty-seven of 39 pinned sandwich portfolios made money against vanilla sequential execution. None made money after Firstless clearing in the tested model.</p></div>
      <div className="mt-4 grid grid-cols-4 gap-3 max-[700px]:grid-cols-2">{[["149", "passing Foundry tests"], ["655,360", "release-depth stateful calls"], ["10,000", "cases for each deep fuzz property"], ["100%", "production lines and functions covered"]].map(([value, label]) => <article key={value} className="grid min-h-44 content-end gap-2 rounded-2xl bg-[#fbfaf6]/70 p-5 max-[700px]:min-h-36"><strong className="font-mono text-[clamp(1.7rem,3.2vw,3.5rem)] font-normal tracking-[-.06em]">{value}</strong><span className="text-[.8rem] text-[#666962]">{label}</span></article>)}</div>
      <p className="ml-auto mt-10 max-w-[62rem] text-[1.05rem] leading-relaxed text-[#666962]">These results are evidence for the tested scope. They are not an audit and do not prove that every MEV strategy or software defect is impossible.</p>
    </section>

    <section className={`${section} bg-[#fbfaf6]`} aria-labelledby="deployment-title">
      <Heading number="06" eyebrow="Unichain Sepolia" id="deployment-title">Inspect the deployed contracts.</Heading>
      <div className="-mt-8 mb-8 ml-20 flex flex-wrap gap-2 font-mono text-[.65rem] text-[#666962] max-[700px]:m-0 max-[700px]:mb-6"><span className="rounded-full bg-[#ecebe5] px-3 py-2">Chain ID {deployment.chainId}</span><span className="rounded-full bg-[#ecebe5] px-3 py-2">Deployed at block {deployment.deploymentBlock}</span><span className="rounded-full bg-[#ecebe5] px-3 py-2">Pool {shortAddress(deployment.poolId)}</span></div>
      <div className="ml-auto grid max-w-[86rem]">{contracts.map(([name, address]) => <a className="group grid min-h-20 grid-cols-[1fr_auto_2rem] items-center gap-4 border-t border-black/15 max-[700px]:grid-cols-[1fr_auto]" key={name} href={`${deployment.explorerUrl}/address/${address}`} target="_blank" rel="noreferrer"><span className="text-lg font-[570]">{name}</span><code className="font-mono text-[.68rem] text-[#666962] group-hover:text-[#2852a2] max-[700px]:hidden">{shortAddress(address)}</code><ArrowUpRight className="size-4" aria-hidden="true" /></a>)}</div>
    </section>

    <section id="limits" className={`${section} bg-[#1b1d19] text-[#f2f1eb]`} aria-labelledby="limits-title">
      <Heading number="07" eyebrow="The honest boundary" id="limits-title" light>What Firstless covers today.</Heading>
      <div className="ml-auto grid max-w-[86rem] grid-cols-2 gap-4 max-[700px]:grid-cols-1">
        <div className="rounded-3xl bg-[#bac7b7] p-8 text-[#1e251f]"><h3 className="mb-6 text-3xl font-[570]">Supported</h3><ul className="grid list-none gap-4 p-0">{["Exact-output orders", "One Firstless pool and canonical-block set", "Conventional ERC-20 pairs", "Orders through the signed router"].map(item => <li className="flex gap-3 leading-snug text-[#3d4a40]" key={item}><Check className="size-4 shrink-0" aria-hidden="true" /> {item}</li>)}</ul></div>
        <div className="rounded-3xl bg-[#242622] p-8"><h3 className="mb-6 text-3xl font-[570]">Not claimed</h3><ul className="grid list-none gap-4 p-0">{["Universal MEV prevention", "Cross-pool or cross-block protection", "Censorship resistance or external-price LVR protection", "Production readiness or an independent audit"].map(item => <li className="leading-snug text-[#b4b6af]" key={item}>{item}</li>)}</ul></div>
      </div>
    </section>

    <section className="grid grid-cols-[1fr_auto_auto] items-end gap-4 bg-[#d8dad2] px-[6vw] py-32 max-[700px]:grid-cols-1 max-[700px]:px-[1.1rem] max-[700px]:py-24"><div><p className="mb-4 font-mono text-[.65rem] text-[#5d695f]">Run the whole path</p><h2 className="max-w-[17ch] text-[clamp(3rem,5.5vw,6.2rem)] font-[550] leading-[.92] tracking-[-.07em] max-[700px]:mb-6 max-[700px]:text-[3.4rem]">See the contracts produce the trade, bill, and refund.</h2></div><button type="button" className="inline-flex min-h-13 items-center justify-center gap-2 rounded-full bg-[#171815] px-5 text-xs font-semibold text-[#fbfaf6]" onClick={onOpenDashboard}>open the dashboard <ArrowUpRight className="size-4" aria-hidden="true" /></button><a className="inline-flex min-h-13 items-center justify-center gap-2 rounded-full border border-black/15 bg-white/60 px-5 text-xs font-semibold" href="https://github.com/aryan877/firstless" target="_blank" rel="noreferrer">read the source <ArrowUpRight className="size-4" aria-hidden="true" /></a></section>
    <footer className="grid min-h-40 grid-cols-[1fr_auto_auto] items-center gap-8 bg-[#121310] px-[6vw] py-10 font-mono text-[.65rem] text-[#a8aaa3] max-[700px]:grid-cols-1 max-[700px]:gap-4 max-[700px]:px-[1.1rem]"><span className="[&_.brand__mark]:invert [&_.brand__name]:text-[#f0efe9]"><Brand light /></span><span>Experimental, unaudited software. Test tokens have no value.</span><button className="border-0 bg-transparent text-[#d7d8d1]" type="button" onClick={onOpenStory}>back to the story</button></footer>
  </main>;
}
