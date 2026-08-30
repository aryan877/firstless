import { motion, useReducedMotion } from "motion/react";

type ClearingStationProps = {
  scene: number;
  compact?: boolean;
};

export function ClearingStation({ scene, compact = false }: ClearingStationProps) {
  const reduceMotion = useReducedMotion();
  const repeat = reduceMotion ? 0 : Number.POSITIVE_INFINITY;
  const active = Math.min(scene, 4);

  return (
    <div className={`clearing-flow ${compact ? "clearing-flow--compact" : ""}`} aria-label="Animated Firstless clearing round">
      <svg viewBox="0 0 720 360" role="img" aria-labelledby="clearing-title clearing-desc">
        <title id="clearing-title">A Firstless round clearing two opposite orders</title>
        <desc id="clearing-desc">Blue and rust orders arrive together, meet in one clearing round, and produce a smaller final bill and refund.</desc>

        <path className="clearing-flow__lane" d="M54 160H282M438 160h228" />
        <path className="clearing-flow__return" d="M360 236v48c0 20-16 36-36 36h-94" />
        <path className="clearing-flow__return" d="M360 284c0 20 16 36 36 36h94" />

        <g className="clearing-flow__label">
          <text x="54" y="128">Alice</text>
          <text x="666" y="128" textAnchor="end">Bob</text>
          <text x="360" y="42" textAnchor="middle">setwise marginal bills</text>
        </g>

        <motion.g
          animate={reduceMotion ? undefined : { x: [0, 205, 205, 0], opacity: [1, 1, .3, 1] }}
          transition={{ duration: 4.8, repeat, times: [0, .32, .68, 1], ease: "easeInOut" }}
        >
          <circle className="clearing-flow__token clearing-flow__token--blue" cx="90" cy="160" r="24" />
          <circle className="clearing-flow__token clearing-flow__token--blue-soft" cx="146" cy="160" r="12" />
        </motion.g>
        <motion.g
          animate={reduceMotion ? undefined : { x: [0, -205, -205, 0], opacity: [1, 1, .3, 1] }}
          transition={{ duration: 4.8, repeat, times: [0, .32, .68, 1], ease: "easeInOut" }}
        >
          <circle className="clearing-flow__token clearing-flow__token--rust" cx="630" cy="160" r="24" />
          <circle className="clearing-flow__token clearing-flow__token--rust-soft" cx="574" cy="160" r="12" />
        </motion.g>

        <motion.g
          className="clearing-flow__chamber"
          animate={reduceMotion ? undefined : { rotate: [0, 0, 180, 180, 360], scale: [1, 1, 1.035, 1, 1] }}
          transition={{ duration: 4.8, repeat, times: [0, .3, .48, .72, 1], ease: "easeInOut" }}
          style={{ transformOrigin: "360px 160px" }}
        >
          <circle cx="360" cy="160" r="78" />
          <path d="M322 160a38 38 0 0 1 68-23" />
          <path d="m386 124 8 16-17-1" />
          <path d="M398 160a38 38 0 0 1-68 23" />
          <path d="m334 196-8-16 17 1" />
        </motion.g>

        <motion.g
          className="clearing-flow__receipt"
          animate={reduceMotion ? undefined : { y: [-10, -10, 0, 0, -10], opacity: [0, 0, 1, 1, 0] }}
          transition={{ duration: 4.8, repeat, times: [0, .44, .58, .84, 1], ease: "easeOut" }}
        >
          <rect x="292" y="234" width="136" height="48" rx="24" />
          <text x="360" y="264" textAnchor="middle">fair bill</text>
        </motion.g>

        <motion.circle
          className="clearing-flow__refund-dot"
          cx="230"
          cy="320"
          r="10"
          animate={reduceMotion ? undefined : { scale: [0, 0, 1, 1, 0], opacity: [0, 0, 1, 1, 0] }}
          transition={{ duration: 4.8, repeat, times: [0, .58, .67, .88, 1] }}
        />
        <motion.circle
          className="clearing-flow__bill-dot"
          cx="490"
          cy="320"
          r="10"
          animate={reduceMotion ? undefined : { scale: [0, 0, 1, 1, 0], opacity: [0, 0, 1, 1, 0] }}
          transition={{ duration: 4.8, repeat, times: [0, .58, .67, .88, 1] }}
        />
        <g className="clearing-flow__bottom-label">
          <text x="210" y="349" textAnchor="middle">refund</text>
          <text x="510" y="349" textAnchor="middle">final payment</text>
        </g>
      </svg>

      {!compact && (
        <div className="clearing-flow__legend" aria-hidden="true">
          <span className={active >= 0 ? "is-active" : ""}>signed</span>
          <span className={active >= 1 ? "is-active" : ""}>output sent</span>
          <span className={active >= 2 ? "is-active" : ""}>orders meet</span>
          <span className={active >= 3 ? "is-active" : ""}>bill settles</span>
        </div>
      )}
    </div>
  );
}
