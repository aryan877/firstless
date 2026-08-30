import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react";
import ArrowRight from "lucide-react/dist/esm/icons/arrow-right.mjs";
import Pause from "lucide-react/dist/esm/icons/pause.mjs";
import Play from "lucide-react/dist/esm/icons/play.mjs";

const steps = [
  {
    label: "The complete set",
    tab: "Whole block",
    title: "Put all three legs on the table.",
    body: "Eve buys 100, Alice buys 10, then Eve sells 100 in the same block. Firstless records the complete set before anybody’s final bill is known.",
  },
  {
    label: "Opposing flow nets",
    tab: "Net flow",
    title: "Eve’s round trip meets itself.",
    body: "The 100-token buy and the opposite 100-token sell cross at the opening reserve ratio. Alice’s 10-token residual is the only part left to move the curve.",
  },
  {
    label: "The set without Alice",
    tab: "Without Alice",
    title: "Ask what Alice added.",
    body: "For Alice’s input token, compare the complete set with the exact same set after removing only Alice. Eve is present in both calculations, so her ordering position cannot be handed to Alice as a bill.",
  },
  {
    label: "Alice’s marginal bill",
    tab: "Final bill",
    title: "Charge the difference. Return the rest.",
    body: "Alice pays the incremental cost her order adds. Eve’s two legs each pay their own marginal contribution and trading fee, so the round trip finishes negative in the tested model.",
  },
] as const;

type OrderCardProps = {
  actor: "Eve" | "Alice";
  action: string;
  token: "fETH" | "fUSD";
  tone: "eve" | "alice";
  motionState: "full" | "net" | "without" | "bill";
  side: "left" | "middle" | "right";
};

function OrderCard({ actor, action, token, tone, motionState, side }: OrderCardProps) {
  const isEve = tone === "eve";
  const isNetted = motionState !== "full" && isEve;
  const isRemoved = motionState === "without" && !isEve;
  const direction = side === "left" ? 92 : side === "right" ? -92 : 0;

  return (
    <motion.div
      className={`marginal-order marginal-order--${tone}`}
      animate={{
        x: isNetted ? direction : 0,
        y: isRemoved ? 24 : 0,
        opacity: isRemoved ? 0.14 : isNetted ? 0.34 : 1,
        scale: isNetted ? 0.9 : isRemoved ? 0.94 : 1,
      }}
      transition={{ type: "spring", stiffness: 180, damping: 24 }}
    >
      <span>{actor}</span>
      <strong>{action}</strong>
      <small>{token}</small>
      {isNetted && <motion.i initial={{ scaleX: 0 }} animate={{ scaleX: 1 }} />}
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
    const interval = window.setInterval(() => setStep((value) => (value + 1) % steps.length), 3300);
    return () => window.clearInterval(interval);
  }, [inView, playing, reduceMotion]);

  const motionState = (["full", "net", "without", "bill"] as const)[step];

  return (
    <section ref={sectionRef} id="math" className="marginal-math" aria-labelledby="marginal-math-title">
      <div className="marginal-math__intro">
        <p>The math, in motion</p>
        <h2 id="marginal-math-title">Full set. Minus the set without me.</h2>
        <p className="marginal-math__lede">
          An illustrative 1:1 pool with 1,000 units on each side and a 30 bps fee. Displayed decimals omit the tiny raw-unit rounding buffer.
        </p>
      </div>

      <div className="marginal-machine">
        <div className="marginal-machine__orders" aria-label="One sandwich-shaped clearing set">
          <OrderCard actor="Eve" action="buys 100" token="fETH" tone="eve" motionState={motionState} side="left" />
          <OrderCard actor="Alice" action="buys 10" token="fETH" tone="alice" motionState={motionState} side="middle" />
          <OrderCard actor="Eve" action="sells for 100" token="fUSD" tone="eve" motionState={motionState} side="right" />
        </div>

        <div className="marginal-machine__rail" aria-hidden="true">
          <motion.span animate={{ scaleX: step >= 1 ? 1 : 0.12 }} />
          <i>opening reserve ratio</i>
        </div>

        <AnimatePresence mode="wait">
          <motion.div
            key={step}
            className="marginal-machine__result"
            initial={reduceMotion ? false : { opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            exit={reduceMotion ? undefined : { opacity: 0, y: -12 }}
            transition={{ duration: reduceMotion ? 0 : 0.3 }}
          >
            {step === 0 && (
              <div className="marginal-set-card">
                <span>complete set</span>
                <strong>3 signed orders</strong>
                <small>No “attacker” label is trusted onchain.</small>
              </div>
            )}
            {step === 1 && (
              <div className="marginal-net-card">
                <div><span>Eve buy</span><strong>100 fETH</strong></div>
                <b>nets</b>
                <div><span>Eve sell</span><strong>100 fUSD @ 1:1</strong></div>
                <ArrowRight aria-hidden="true" />
                <div className="is-residual"><span>curve residual</span><strong>Alice’s 10 fETH</strong></div>
              </div>
            )}
            {step === 2 && (
              <div className="marginal-subtraction">
                <div><span>full-set fUSD cost</span><strong>110.432</strong></div>
                <b>minus</b>
                <div><span>without Alice</span><strong>100.301</strong></div>
              </div>
            )}
            {step === 3 && (
              <div className="marginal-final">
                <div className="marginal-final__formula">
                  <span>Alice’s final bill</span>
                  <strong>110.432 − 100.301</strong>
                  <b>10.131 fUSD + buffer</b>
                </div>
                <div className="marginal-final__eve">
                  <span>Eve’s round trip</span>
                  <strong>receives 100 + 100</strong>
                  <b>pays 100.402 + 100.301</b>
                  <small>negative before any external gas</small>
                </div>
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
                <b>{item.tab}</b>
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
        Honest boundary: a same-direction fake can still worsen a victim’s marginal bill. The protection is that the fake pays at least the harm it creates; the historical sandwich claim concerns opposing attack legs inside the same set.
      </p>
    </section>
  );
}
