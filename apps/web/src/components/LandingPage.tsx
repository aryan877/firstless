import { useEffect, useRef } from "react";
import { motion, useReducedMotion } from "motion/react";
import ArrowDownRight from "lucide-react/dist/esm/icons/arrow-down-right.mjs";
import ArrowRight from "lucide-react/dist/esm/icons/arrow-right.mjs";
import ArrowUpRight from "lucide-react/dist/esm/icons/arrow-up-right.mjs";
import { Brand } from "@/components/Brand";
import { MarginalMath } from "@/components/MarginalMath";
import "@/landing-v2.css";

type LandingPageProps = {
  onOpenDashboard: () => void;
};

type MotionAssetName = "alice" | "bob" | "eve" | "liam" | "clearing-table" | "liquidity-platform";

const motionAssets: Record<MotionAssetName, string> = {
  alice: "/motion/alice.webm",
  bob: "/motion/bob.webm",
  eve: "/motion/eve.webm",
  liam: "/motion/liam.webm",
  "clearing-table": "/motion/clearing-table.webm",
  "liquidity-platform": "/motion/liquidity-platform.webm",
};

function MotionAsset({
  name,
  className,
  reduceMotion,
}: {
  name: MotionAssetName;
  className: string;
  reduceMotion: boolean | null;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const videoSrc = motionAssets[name];

  useEffect(() => {
    const video = videoRef.current;
    if (!video || reduceMotion) return;

    if (!("IntersectionObserver" in window)) {
      void video.play().catch(() => undefined);
      return;
    }

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          void video.play().catch(() => undefined);
        } else {
          video.pause();
        }
      },
      { threshold: .08 },
    );
    observer.observe(video);
    return () => observer.disconnect();
  }, [reduceMotion]);

  return (
    <video
      ref={videoRef}
      className={className}
      loop={!reduceMotion}
      muted
      playsInline
      preload={reduceMotion ? "auto" : "metadata"}
      aria-hidden="true"
      tabIndex={-1}
    >
      <source src={videoSrc} type="video/webm" />
    </video>
  );
}

const scenes = [
  {
    id: "promise",
    alt: "Alice makes a precise token trade while Eve is blocked from cutting ahead",
    marker: "Alice makes a promise",
    title: "Exactly 10. Not roughly 10.",
    body: "Alice signs the amount she wants and the most she will pay. Nobody carrying her order can change either number.",
    side: "Her 10 fETH is usable now.",
    signal: "signed",
  },
  {
    id: "wait",
    alt: "Bob arrives while Alice’s maximum input waits through one Ethereum block",
    marker: "Ethereum keeps the set open",
    title: "One Ethereum block.",
    body: "Alice can already use her output. Her maximum input stays reserved while opposite orders join the same Ethereum block.",
    side: "Bob arrives before the block closes.",
    signal: "Ethereum block",
  },
  {
    id: "clear",
    alt: "Alice and Bob exchange opposite tokens while only a small remainder reaches the pool",
    marker: "The block set clears together",
    title: "Alice meets Bob before the pool.",
    body: "Their opposite needs cancel each other. Only the little leftover reaches the price curve, so arriving first inside the block set gives no special deal.",
    side: "One set. Individual marginal bills.",
    signal: "fair",
  },
  {
    id: "liquidity",
    alt: "Liam puts two tokens on a waiting platform before receiving an LP ownership ticket",
    marker: "Liam stocks the pool",
    title: "His money waits. His ownership waits too.",
    body: "Liam deposits both tokens. After a later Ethereum block, they activate at the pool’s current reserve ratio and his LP shares appear at the same moment.",
    side: "No shares means no old fees to grab.",
    signal: "pending",
  },
] as const;

function EthereumLockup({ short = false }: { short?: boolean }) {
  return (
    <span className="fl-ethereum-lockup">
      <span aria-hidden="true">◆</span>
      {short ? "Ethereum" : "Ethereum block"}
    </span>
  );
}

function BlockClock({ reduceMotion }: { reduceMotion: boolean | null }) {
  const loop = reduceMotion ? 0 : Number.POSITIVE_INFINITY;

  return (
    <div className="fl-block-clock" aria-hidden="true">
      <svg viewBox="0 0 180 180">
        <circle className="fl-block-clock__track" cx="90" cy="90" r="72" />
        <motion.circle
          className="fl-block-clock__progress"
          cx="90"
          cy="90"
          r="72"
          pathLength="1"
          whileInView={reduceMotion ? undefined : { pathLength: [0, 1, 1], opacity: [1, 1, 0] }}
          viewport={{ amount: .45 }}
          transition={{ duration: 3.2, repeat: loop, times: [0, .82, 1], ease: "easeInOut" }}
        />
      </svg>
      <div>
        <strong>1 block</strong>
        <span>output now · refund next block</span>
      </div>
    </div>
  );
}

function SplitWords({ children }: { children: string }) {
  return (
    <>
      {children.split(" ").map((word, index) => (
        <motion.span
          className="fl-word-mask"
          key={`${word}-${index}`}
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true, amount: .8 }}
        >
          <motion.span
            className="fl-word"
            variants={{ hidden: { y: "115%" }, visible: { y: 0 } }}
            transition={{ duration: 0.72, delay: index * 0.035, ease: [0.22, 1, 0.36, 1] }}
          >
            {word}&nbsp;
          </motion.span>
        </motion.span>
      ))}
    </>
  );
}

function ClearingTable({ reduceMotion }: { reduceMotion: boolean | null }) {
  return (
    <div className="scene-table scene-table--animated" aria-hidden="true">
      <MotionAsset name="clearing-table" className="scene-table__base" reduceMotion={reduceMotion} />
    </div>
  );
}

function SceneArtwork({ id, alt, reduceMotion }: { id: string; alt: string; reduceMotion: boolean | null }) {
  return (
    <motion.div
      className={`fl-scene-art fl-scene-art--${id}`}
      role="img"
      aria-label={alt}
      initial={reduceMotion ? false : { opacity: 0, x: 34 }}
      animate={{ opacity: 1, x: 0 }}
      transition={{ duration: .72, ease: [0.22, 1, 0.36, 1] }}
    >
      {id === "promise" && (
        <>
          <MotionAsset name="alice" className="scene-alice" reduceMotion={reduceMotion} />
          <img className="scene-gate" src="/props/order-gate.svg" alt="" />
          <MotionAsset name="eve" className="scene-eve" reduceMotion={reduceMotion} />
        </>
      )}
      {id === "wait" && (
        <>
          <MotionAsset name="clearing-table" className="scene-table" reduceMotion={reduceMotion} />
          <MotionAsset name="bob" className="scene-bob" reduceMotion={reduceMotion} />
          <BlockClock reduceMotion={reduceMotion} />
        </>
      )}
      {id === "clear" && (
        <>
          <ClearingTable reduceMotion={reduceMotion} />
          <MotionAsset name="alice" className="scene-alice" reduceMotion={reduceMotion} />
          <MotionAsset name="bob" className="scene-bob" reduceMotion={reduceMotion} />
        </>
      )}
      {id === "liquidity" && (
        <>
          <MotionAsset name="liquidity-platform" className="scene-platform" reduceMotion={reduceMotion} />
          <MotionAsset name="liam" className="scene-liam" reduceMotion={reduceMotion} />
        </>
      )}
    </motion.div>
  );
}

export function LandingPage({ onOpenDashboard }: LandingPageProps) {
  const reduceMotion = useReducedMotion();

  useEffect(() => {
    if (!window.location.hash) return;
    document.querySelector(window.location.hash)?.scrollIntoView();
  }, []);

  return (
    <main id="top" className="fl-landing">
      <header className="fl-nav">
        <Brand />
        <nav aria-label="Main navigation">
          <a href="#how">how it clears</a>
          <a href="#math">the math</a>
          <a href="#refund">the refund</a>
          <a href="#proof">proof</a>
        </nav>
        <button className="fl-nav__button" onClick={onOpenDashboard}>
          open dashboard <ArrowUpRight aria-hidden="true" />
        </button>
      </header>

      <section className="fl-hero" aria-labelledby="fl-hero-title">
        <div className="fl-paper-noise" aria-hidden="true" />
        <motion.div
          className="fl-hero__copy"
          initial={reduceMotion ? false : { opacity: 0, y: 36 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, ease: [0.22, 1, 0.36, 1] }}
        >
          <p className="fl-kicker"><EthereumLockup short /> Setwise clearing for Uniswap v4</p>
          <h1 id="fl-hero-title"><span>Trade now.</span><em>Settle together.</em></h1>
          <p className="fl-hero__lede">Your output arrives now. The complete Ethereum block determines the final bill and refund.</p>
          <div className="fl-hero__actions">
            <a href="#how">see the set <ArrowDownRight aria-hidden="true" /></a>
            <button onClick={onOpenDashboard}>try the product <ArrowRight aria-hidden="true" /></button>
          </div>
        </motion.div>

        <motion.figure
          className="fl-hero__cast"
          initial={reduceMotion ? false : { opacity: 0, x: 48 }}
          animate={{ opacity: 1, x: 0 }}
          transition={{ duration: 1.1, delay: 0.18, ease: [0.22, 1, 0.36, 1] }}
        >
          <div className="fl-hero__people" role="img" aria-label="Alice, Bob, Eve and Liam, the people in the Firstless story">
            <MotionAsset name="alice" className="is-alice" reduceMotion={reduceMotion} />
            <MotionAsset name="bob" className="is-bob" reduceMotion={reduceMotion} />
            <MotionAsset name="eve" className="is-eve" reduceMotion={reduceMotion} />
            <MotionAsset name="liam" className="is-liam" reduceMotion={reduceMotion} />
            <svg className="fl-hero__role-badge fl-hero__role-badge--eve" viewBox="0 0 112 36" aria-hidden="true">
              <rect x="1" y="1" width="110" height="34" rx="17" />
              <text x="56" y="23" textAnchor="middle">attacker</text>
            </svg>
            <svg className="fl-hero__role-badge fl-hero__role-badge--liam" viewBox="0 0 58 36" aria-hidden="true">
              <rect x="1" y="1" width="56" height="34" rx="17" />
              <text x="29" y="23" textAnchor="middle">LP</text>
            </svg>
          </div>
          <figcaption>
            <span className="is-alice"><b>Alice</b> wants an exact trade</span>
            <span className="is-bob"><b>Bob</b> wants the opposite trade</span>
            <span className="is-eve"><b>Eve</b> wants to jump the order</span>
            <span className="is-liam"><b>Liam</b> stocks the pool</span>
          </figcaption>
        </motion.figure>

        <p className="fl-hero__aside">Output now<br />fair bill later</p>
      </section>

      <section className="fl-thesis" aria-label="The Firstless idea">
        <p>Execution position should not become a permanent pricing privilege.</p>
        <span>Each order pays the cost it adds to the completed set—not a uniform price and not a guessed attacker label.</span>
      </section>

      <section id="how" className="fl-story" aria-label="How Firstless clears an Ethereum block set">
        <div className="fl-story__intro">
          <span>How Firstless clears a trade</span>
          <span>Signed output through final refund</span>
        </div>
        <div className="fl-story__list">
          {scenes.map((scene) => (
            <motion.article
              key={scene.id}
              id={`scene-${scene.id}`}
              className={`fl-scene fl-scene--${scene.id}`}
              initial={reduceMotion ? false : { opacity: 0, y: 44 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, amount: .16 }}
              transition={{ duration: reduceMotion ? 0 : .38, ease: [0.22, 1, 0.36, 1] }}
            >
              <div className="fl-scene__copy">
                <p>{scene.marker}</p>
                <h2><SplitWords>{scene.title}</SplitWords></h2>
                <div className="fl-scene__body">{scene.body}</div>
              </div>
              <SceneArtwork id={scene.id} alt={scene.alt} reduceMotion={reduceMotion} />
              <p className="fl-scene__side">{scene.side}</p>
              <strong className="fl-scene__signal">
                {scene.id === "wait" ? <EthereumLockup /> : scene.signal}
              </strong>
            </motion.article>
          ))}
        </div>
      </section>

      <MarginalMath />

      <section id="refund" className="fl-refund" aria-labelledby="refund-title">
        <div className="fl-refund__intro">
          <p>When the block set settles</p>
          <h2 id="refund-title">The maximum was a safety deposit. It was never the price.</h2>
        </div>
        <div className="fl-refund__math" aria-label="12.2468 fUSD maximum minus 10.1314 fUSD final bill equals a 2.1153 fUSD refund">
          <p>Same Alice · same 10 fETH order</p>
          <div><span>Maximum escrowed at signature</span><strong>12.2468 <small>fUSD</small></strong></div>
          <b className="fl-refund__operator" aria-hidden="true">−</b>
          <div><span>Final marginal bill after the block</span><strong>10.1314 <small>fUSD</small></strong></div>
          <b className="fl-refund__operator" aria-hidden="true">=</b>
          <div className="is-result"><span>Refund returned to Alice</span><strong>2.1153 <small>fUSD</small></strong></div>
        </div>
        <p className="fl-refund__note">Alice could use her 10 fETH output immediately. Only the final bill and refund waited for the completed Ethereum block.</p>
      </section>

      <section id="proof" className="fl-proof" aria-labelledby="proof-title">
        <div className="fl-proof__number">0 <span>/ 39</span></div>
        <div className="fl-proof__copy">
          <p>profitable Firstless attacker portfolios</p>
          <h2 id="proof-title">37 were profitable in the vanilla replay. Zero were profitable after setwise clearing.</h2>
        </div>
      </section>

      <section className="fl-dashboard" aria-labelledby="dashboard-title">
        <div className="fl-dashboard__copy">
          <p>Now use the idea</p>
          <h2 id="dashboard-title">Trade, claim refunds, or stock the pool.</h2>
          <button onClick={onOpenDashboard}>open the dashboard <ArrowUpRight aria-hidden="true" /></button>
        </div>
        <button className="fl-dashboard__window" onClick={onOpenDashboard} aria-label="Open the dashboard preview">
          <div className="fl-dashboard__bar"><i /><i /><i /><span>Firstless clearing console</span><b>ready</b></div>
          <div className="fl-dashboard__screen">
            <aside><span className="is-on" /><span /><span /><span /></aside>
            <div className="fl-dashboard__trade">
              <p>you receive</p><strong>10.0000</strong><small>fETH</small>
              <div><span>maximum held</span><b>12.2468 fUSD</b></div>
              <span className="fl-dashboard__fake-button">sign exact output</span>
            </div>
            <div className="fl-dashboard__round"><span>current Ethereum block</span><b>collecting</b><i /><small>refund settles next block</small></div>
          </div>
        </button>
      </section>

      <footer className="fl-footer">
        <Brand light />
        <p>Less ordering power.<br />More honest clearing.</p>
        <button onClick={onOpenDashboard}>open dashboard <ArrowUpRight aria-hidden="true" /></button>
        <span>Built for the Uniswap Hook Incubator. Experimental, unaudited software.</span>
      </footer>
    </main>
  );
}
