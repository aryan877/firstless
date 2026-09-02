import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react";
import Pause from "lucide-react/dist/esm/icons/pause.mjs";
import Play from "lucide-react/dist/esm/icons/play.mjs";

const steps = [
  {
    label: "1 · Complete set",
    tab: "Set",
    title: "Price the completed block, not its ordering.",
    body: "The calculation starts only after Eve’s buy, Alice’s buy, and Eve’s reversing sell are all known. Every order uses the same opening reserves.",
  },
  {
    label: "2 · Net opposing flow",
    tab: "Net",
    title: "Eve’s opposite legs meet before the curve.",
    body: "At the opening 1:1 reserve ratio, Eve’s 100-token buy and 100-token sell offset. Alice’s 10 fETH is the residual that reaches the AMM curve.",
  },
  {
    label: "3 · Leave Alice out once",
    tab: "Subtract",
    title: "Run the same block again without Alice.",
    body: "The comparison keeps Eve’s two orders and the same opening reserves. Removing only Alice isolates the pool cost caused by Alice’s exact-output request.",
  },
  {
    label: "4 · Alice’s final bill",
    tab: "Bill",
    title: "Charge the difference. Refund the unused maximum.",
    body: "Alice receives 10 fETH immediately and settles 10.1314 fUSD plus the eight-wei rounding buffer. Her larger signed maximum was temporary collateral.",
  },
] as const;

type OrderCardProps = {
  actor: "Eve" | "Alice";
  action: string;
  token: "fETH" | "fUSD";
  tone: "eve" | "alice";
  motionState: "full" | "net" | "without" | "bill";
};

function OrderCard({ actor, action, token, tone, motionState }: OrderCardProps) {
  const isEve = tone === "eve";
  const isNetted = motionState === "net" && isEve;
  const isRemoved = motionState === "without" && !isEve;
  const isFocused = motionState === "bill" && !isEve;

  return (
    <motion.div
      className={`marginal-order marginal-order--${tone}${isNetted ? " is-netted" : ""}${isRemoved ? " is-removed" : ""}${isFocused ? " is-focused" : ""}`}
      animate={{
        opacity: isRemoved ? 0.22 : isNetted ? 0.48 : 1,
        scale: isRemoved || isNetted ? 0.98 : 1,
      }}
      transition={{ duration: 0.32, ease: "easeOut" }}
    >
      <span>{actor}</span>
      <strong>{action}</strong>
      <small>{token}</small>
      {isNetted && <motion.i initial={{ scaleX: 0 }} animate={{ scaleX: 1 }} transition={{ duration: 0.28 }} />}
      {isRemoved && <em>removed for comparison</em>}
    </motion.div>
  );
}

export function MarginalMath() {
  const sectionRef = useRef<HTMLElement>(null);
  const inView = useInView(sectionRef, { amount: 0.35 });
  const reduceMotion = useReducedMotion();
  const [step, setStep] = useState(0);
  const [playing, setPlaying] = useState(true);

  useEffect(() => {
    if (!inView || !playing || reduceMotion) return;
    const interval = window.setInterval(() => setStep((value) => (value + 1) % steps.length), 4400);
    return () => window.clearInterval(interval);
  }, [inView, playing, reduceMotion]);

  const motionState = (["full", "net", "without", "bill"] as const)[step];

  return (
    <section ref={sectionRef} id="math" className="marginal-math" aria-labelledby="marginal-math-title">
      <div className="marginal-math__intro">
        <p>The bill in one equation</p>
        <h2 id="marginal-math-title">What did Alice add?</h2>
        <p className="marginal-math__lede">
          One 1:1 pool. One completed Ethereum block. Alice pays only the extra fUSD cost created by her 10 fETH exact-output order.
        </p>
      </div>

      <div className="marginal-machine">
        <div className="marginal-machine__orders" aria-label="One sandwich-shaped clearing set">
          <OrderCard actor="Eve" action="buys 100" token="fETH" tone="eve" motionState={motionState} />
          <OrderCard actor="Alice" action="buys 10" token="fETH" tone="alice" motionState={motionState} />
          <OrderCard actor="Eve" action="sells for 100" token="fUSD" tone="eve" motionState={motionState} />
        </div>

        <div className="marginal-machine__context">
          <span>Opening reserves</span>
          <strong>1,000 fETH : 1,000 fUSD</strong>
          <small>30 bps fee · same snapshot in both calculations</small>
        </div>

        <div className="marginal-equation" aria-label="110.4323 fUSD minus 100.3009 fUSD equals Alice's 10.1314 fUSD marginal bill">
          <div className={`marginal-equation__term${step === 0 || step === 2 ? " is-focus" : ""}`}>
            <span>Cost of all 3 orders</span>
            <strong>110.4323</strong>
            <small>fUSD</small>
          </div>
          <b aria-hidden="true">−</b>
          <div className={`marginal-equation__term${step === 2 ? " is-focus" : ""}`}>
            <span>Cost without Alice</span>
            <strong>100.3009</strong>
            <small>fUSD</small>
          </div>
          <b aria-hidden="true">=</b>
          <div className={`marginal-equation__term marginal-equation__term--result${step === 3 ? " is-focus" : ""}`}>
            <span>Alice’s marginal bill</span>
            <strong>10.1314</strong>
            <small>fUSD + 8 wei buffer</small>
          </div>
        </div>

        <AnimatePresence mode="wait">
          <motion.div
            key={step}
            className="marginal-machine__explanation"
            initial={reduceMotion ? false : { opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={reduceMotion ? undefined : { opacity: 0, y: -8 }}
            transition={{ duration: reduceMotion ? 0 : 0.28, ease: "easeOut" }}
          >
            {step === 0 && (
              <div className="marginal-set-line">
                <span>Completed set</span>
                <strong>Eve buy + Alice buy + Eve sell</strong>
                <small>All three orders are known before any final bill is assigned.</small>
              </div>
            )}
            {step === 1 && (
              <div className="marginal-net-card">
                <div><span>Eve’s opposite legs</span><strong>100 ↔ 100</strong><small>net at the opening 1:1 ratio</small></div>
                <b aria-hidden="true">→</b>
                <div className="is-residual"><span>Residual sent to curve</span><strong>10 fETH</strong><small>Alice’s requested output</small></div>
              </div>
            )}
            {step === 2 && (
              <div className="marginal-compare">
                <div><span>Complete set</span><strong>Eve + Alice + Eve</strong></div>
                <b>remove Alice once</b>
                <div><span>Comparison set</span><strong>Eve + Eve</strong></div>
              </div>
            )}
            {step === 3 && (
              <div className="marginal-outcome">
                <div><span>Alice receives immediately</span><strong>10 fETH</strong></div>
                <div><span>Alice settles after the block</span><strong>10.1314 fUSD</strong><small>plus an 8 wei rounding buffer</small></div>
              </div>
            )}
          </motion.div>
        </AnimatePresence>

        <div className="marginal-machine__controls">
          <button
            type="button"
            className="marginal-machine__play"
            onClick={() => setPlaying((value) => !value)}
            aria-label={playing ? "Pause mechanism animation" : "Play mechanism animation"}
          >
            {playing ? <Pause aria-hidden="true" /> : <Play aria-hidden="true" />}
          </button>
          <div role="tablist" aria-label="Mechanism animation steps">
            {steps.map((item, index) => (
              <button
                type="button"
                role="tab"
                aria-selected={step === index}
                className={step === index ? "is-active" : ""}
                key={item.label}
                onClick={() => {
                  setStep(index);
                  setPlaying(false);
                }}
              >
                {step === index && <motion.span layoutId="marginal-active-step" transition={{ type: "spring", stiffness: 360, damping: 32 }} />}
                <b>{index + 1}. {item.tab}</b>
              </button>
            ))}
          </div>
        </div>
      </div>

      <AnimatePresence mode="wait">
        <motion.div
          key={steps[step].label}
          className="marginal-math__copy"
          initial={reduceMotion ? false : { opacity: 0, x: 20 }}
          animate={{ opacity: 1, x: 0 }}
          exit={reduceMotion ? undefined : { opacity: 0, x: -14 }}
        >
          <p>{steps[step].label}</p>
          <h3>{steps[step].title}</h3>
          <span>{steps[step].body}</span>
        </motion.div>
      </AnimatePresence>

      <p className="marginal-math__boundary">
        Exact example: 1,000 / 1,000 opening reserves and a 30 bps fee. Displayed values are rounded to four decimals; the contract adds an 8 wei buffer at this 1:1 reserve ratio. No attacker label is trusted onchain.
      </p>
    </section>
  );
}
