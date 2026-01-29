#!/usr/bin/env guile3
!#
;;; generate-showcase.scm --- Generate 100 showcase images for blog/README use
;;;
;;; Usage: guile3 -L src scripts/generate-showcase.scm
;;; Output: tests/fixtures/showcase/ with GENERATION_LOG.csv

(add-to-load-path (string-append (dirname (current-filename)) "/../src"))

(use-modules (sage config)
             (sage util)
             (sage ollama)
             (srfi srfi-19)
             (ice-9 format)
             (ice-9 textual-ports))

(config-load-dotenv)

(define *output-dir*
  (string-append (dirname (current-filename)) "/../tests/fixtures/showcase"))

(define *log-path*
  (string-append *output-dir* "/GENERATION_LOG.csv"))

(define *total* 0)
(define *succeeded* 0)
(define *failed* 0)

;; Ensure output dir exists
(unless (file-exists? *output-dir*)
  (mkdir *output-dir*))

;; Open log file
(define *log-port* (open-output-file *log-path*))
(format *log-port* "seq,filename,width,height,time_s,size_bytes,category,prompt,model,host,status~%")

(define (generate seq category prompt filename w h)
  (set! *total* (1+ *total*))
  (let* ((path (string-append *output-dir* "/" filename ".png"))
         (t0 (time-second (current-time))))
    (catch #t
      (lambda ()
        (ollama-generate-image prompt path #:width w #:height h)
        (let* ((t1 (time-second (current-time)))
               (elapsed (- t1 t0))
               (size (stat:size (stat path))))
          (set! *succeeded* (1+ *succeeded*))
          (format *log-port* "~a,~a.png,~a,~a,~a,~a,~a,\"~a\",~a,~a,ok~%"
                  seq filename w h elapsed size category prompt
                  (ollama-image-model) (ollama-image-host))
          (force-output *log-port*)
          (format #t "[~3d/100] ~a (~ax~a) ~as ~aKB - ~a~%"
                  seq filename w h elapsed (quotient size 1024) category)))
      (lambda (key . args)
        (set! *failed* (1+ *failed*))
        (let* ((t1 (time-second (current-time)))
               (elapsed (- t1 t0)))
          (format *log-port* "~a,~a.png,~a,~a,~a,0,~a,\"~a\",~a,~a,FAIL:~a~%"
                  seq filename w h elapsed category prompt
                  (ollama-image-model) (ollama-image-host) key)
          (force-output *log-port*)
          (format #t "[~3d/100] FAIL ~a - ~a~%" seq filename key))))))

;;; ============================================================
;;; 100 Prompts organized by category
;;; ============================================================

(format #t "~%Generating 100 showcase images...~%")
(format #t "Model: ~a~%" (ollama-image-model))
(format #t "Host: ~a~%" (ollama-image-host))
(format #t "Output: ~a~%~%" *output-dir*)

;; --- 1-10: Scheme/Lisp/Programming ---
(generate  1 "programming" "lambda calculus symbol glowing in neon purple on dark background" "lambda-neon" 512 512)
(generate  2 "programming" "abstract syntax tree visualization, colorful nodes and edges on dark background" "ast-visualization" 512 512)
(generate  3 "programming" "parentheses nested in fractal pattern, lisp-inspired art" "parens-fractal" 512 512)
(generate  4 "programming" "terminal screen with green text on black, hacker aesthetic" "terminal-green" 512 512)
(generate  5 "programming" "recursive function visualization, fibonacci spiral made of code" "recursive-fibonacci" 512 512)
(generate  6 "programming" "binary tree data structure, minimalist line art on white" "binary-tree" 512 512)
(generate  7 "programming" "git branch diagram, colorful branches merging, technical illustration" "git-branches" 512 512)
(generate  8 "programming" "stack of colorful function calls, debug visualization" "call-stack" 512 512)
(generate  9 "programming" "scheme repl prompt with s-expressions, retro computer aesthetic" "scheme-repl" 512 512)
(generate 10 "programming" "neural network layers visualization, glowing interconnected nodes" "neural-network" 512 512)

;; --- 11-20: AI/Agent ---
(generate 11 "ai-agent" "robot reading a book in a library, warm lighting" "robot-library" 512 512)
(generate 12 "ai-agent" "artificial brain made of glowing circuits, blue and white" "circuit-brain" 512 512)
(generate 13 "ai-agent" "owl wearing glasses sitting at a computer, digital art" "sage-owl" 512 512)
(generate 14 "ai-agent" "constellation of interconnected AI agents, network diagram style" "agent-network" 512 512)
(generate 15 "ai-agent" "human and robot shaking hands, partnership concept" "human-robot-handshake" 512 512)
(generate 16 "ai-agent" "chat bubbles flowing between two entities, conversation visualization" "chat-flow" 512 512)
(generate 17 "ai-agent" "magnifying glass over source code, code review concept" "code-review" 512 512)
(generate 18 "ai-agent" "toolbox with wrenches and gears, tool-use concept art" "agent-toolbox" 512 512)
(generate 19 "ai-agent" "thought bubble with branching decision tree inside" "decision-tree" 512 512)
(generate 20 "ai-agent" "compass rose with code symbols at cardinal points, navigation concept" "code-compass" 512 512)

;; --- 21-30: Architecture/Infrastructure ---
(generate 21 "infra" "server rack with glowing blue LEDs in dark data center" "server-rack" 512 512)
(generate 22 "infra" "message queue pipeline, flowing data packets illustration" "message-queue" 512 512)
(generate 23 "infra" "microservices architecture diagram, colorful hexagons connected" "microservices" 512 512)
(generate 24 "infra" "container ship made of docker containers, digital art" "docker-ship" 512 512)
(generate 25 "infra" "lighthouse beacon sending signals across network, cyberpunk style" "network-lighthouse" 512 512)
(generate 26 "infra" "bridge connecting two islands, infrastructure metaphor, sunset" "bridge-infra" 512 512)
(generate 27 "infra" "honeycomb pattern of interconnected services, technical illustration" "honeycomb-services" 512 512)
(generate 28 "infra" "watchtower overlooking a digital landscape, security monitoring concept" "watchtower-security" 512 512)
(generate 29 "infra" "pipeline flowing through stages, CI/CD concept art" "cicd-pipeline" 512 512)
(generate 30 "infra" "map with glowing connection lines between cities, distributed systems" "distributed-map" 512 512)

;; --- 31-40: Nature/Organic metaphors ---
(generate 31 "nature" "bonsai tree with circuit board branches, tech-nature fusion" "circuit-bonsai" 512 512)
(generate 32 "nature" "mycelium network underground, glowing connections, cross-section view" "mycelium-network" 512 512)
(generate 33 "nature" "dandelion seeds dispersing in wind, each seed is a data packet" "data-dandelion" 512 512)
(generate 34 "nature" "coral reef ecosystem, vibrant colors, biodiversity" "coral-reef" 512 512)
(generate 35 "nature" "aurora borealis over mountain lake, reflection" "aurora-lake" 512 512)
(generate 36 "nature" "bee pollinating flower, macro photography, golden hour" "bee-pollination" 512 512)
(generate 37 "nature" "crystal cave with glowing minerals, underground wonder" "crystal-cave" 512 512)
(generate 38 "nature" "tree rings cross section showing growth patterns, macro" "tree-rings" 512 512)
(generate 39 "nature" "flock of starlings forming murmuration pattern in sunset sky" "murmuration" 512 512)
(generate 40 "nature" "nautilus shell spiral, golden ratio, mathematical beauty" "nautilus-golden" 512 512)

;; --- 41-50: Abstract/Geometric ---
(generate 41 "abstract" "voronoi diagram in gradient colors, computational geometry" "voronoi-gradient" 512 512)
(generate 42 "abstract" "penrose tiling pattern, impossible geometry, colorful" "penrose-tiling" 512 512)
(generate 43 "abstract" "mobius strip made of flowing data, infinite loop concept" "mobius-data" 512 512)
(generate 44 "abstract" "tessellation pattern inspired by MC Escher, morphing shapes" "escher-tessellation" 512 512)
(generate 45 "abstract" "sacred geometry mandala, intricate symmetric pattern" "sacred-geometry" 512 512)
(generate 46 "abstract" "wave interference pattern, double slit experiment visualization" "wave-interference" 512 512)
(generate 47 "abstract" "impossible triangle made of glass, optical illusion" "impossible-triangle" 512 512)
(generate 48 "abstract" "topographic contour map, elevation lines in earth tones" "topographic-map" 512 512)
(generate 49 "abstract" "op art black and white pattern creating 3D illusion" "op-art-3d" 512 512)
(generate 50 "abstract" "kaleidoscope pattern with jewel tones, symmetric radial design" "kaleidoscope" 512 512)

;; --- 51-60: Retro/Vintage ---
(generate 51 "retro" "vintage computer with CRT monitor, 1980s office" "retro-computer-80s" 512 512)
(generate 52 "retro" "punch card stack, early computing, sepia tone photograph" "punch-cards" 512 512)
(generate 53 "retro" "vacuum tubes glowing orange, old radio electronics" "vacuum-tubes" 512 512)
(generate 54 "retro" "blueprint technical drawing, engineering schematic, blue and white" "blueprint-schematic" 512 512)
(generate 55 "retro" "art deco poster design, geometric patterns, gold and black" "art-deco-poster" 512 512)
(generate 56 "retro" "old typewriter with paper, close-up of typebars" "typewriter-closeup" 512 512)
(generate 57 "retro" "analog synthesizer with patch cables, modular synth" "analog-synth" 512 512)
(generate 58 "retro" "cassette tape with magnetic ribbon unwound artistically" "cassette-art" 512 512)
(generate 59 "retro" "vintage map with compass rose and sea monsters" "vintage-map" 512 512)
(generate 60 "retro" "old clock mechanism, gears and springs, macro photography" "clock-mechanism" 512 512)

;; --- 61-70: Minimalist/Icon ---
(generate 61 "minimal" "single light bulb glowing warmly on dark background, minimal" "lightbulb-idea" 512 512)
(generate 62 "minimal" "paper airplane flying upward, trailing dotted line, white background" "paper-airplane" 512 512)
(generate 63 "minimal" "key and lock, simple elegant illustration, security concept" "key-lock" 512 512)
(generate 64 "minimal" "hourglass with sand flowing, time concept, minimal style" "hourglass-time" 512 512)
(generate 65 "minimal" "seedling growing from soil, growth concept, clean background" "seedling-growth" 512 512)
(generate 66 "minimal" "puzzle pieces fitting together, collaboration concept" "puzzle-pieces" 512 512)
(generate 67 "minimal" "open book with pages turning, knowledge concept" "open-book" 512 512)
(generate 68 "minimal" "anchor symbol, stability concept, nautical minimal art" "anchor-stability" 512 512)
(generate 69 "minimal" "mountain peak with flag, achievement concept, simple illustration" "summit-flag" 512 512)
(generate 70 "minimal" "origami crane, elegant paper fold, minimal white background" "origami-crane" 512 512)

;; --- 71-80: Sci-fi/Futuristic ---
(generate 71 "scifi" "holographic display floating in mid-air, futuristic interface" "holo-display" 512 512)
(generate 72 "scifi" "space elevator reaching into orbit, earth below" "space-elevator" 512 512)
(generate 73 "scifi" "dyson sphere around a star, mega-structure concept art" "dyson-sphere" 512 512)
(generate 74 "scifi" "terraformed mars with oceans and green continents" "terraformed-mars" 512 512)
(generate 75 "scifi" "quantum computer core, glowing qubits in cryogenic chamber" "quantum-computer" 512 512)
(generate 76 "scifi" "warp drive engine room, blue plasma glow, starship interior" "warp-drive" 512 512)
(generate 77 "scifi" "floating city in clouds, solarpunk architecture" "solarpunk-city" 512 512)
(generate 78 "scifi" "alien monolith on barren planet, mysterious artifact" "alien-monolith" 512 512)
(generate 79 "scifi" "cyberpunk alley with neon signs and rain reflections" "cyberpunk-alley" 512 512)
(generate 80 "scifi" "ringworld space habitat, interior view with landscape curving upward" "ringworld" 512 512)

;; --- 81-90: Art styles ---
(generate 81 "art-style" "impressionist painting of a garden path with flowers, monet style" "impressionist-garden" 512 512)
(generate 82 "art-style" "cubist portrait in earth tones, picasso inspired" "cubist-portrait" 512 512)
(generate 83 "art-style" "art nouveau floral border design, mucha style" "art-nouveau-floral" 512 512)
(generate 84 "art-style" "pointillist seascape, dots of color forming waves and sky" "pointillist-sea" 512 512)
(generate 85 "art-style" "pop art comic panel, bold colors, halftone dots" "pop-art-comic" 512 512)
(generate 86 "art-style" "chinese ink wash painting of misty mountains, traditional" "ink-wash-mountains" 512 512)
(generate 87 "art-style" "stained glass window design, gothic cathedral, vibrant colors" "stained-glass" 512 512)
(generate 88 "art-style" "aboriginal dot painting, dreamtime story, earth tones" "aboriginal-dots" 512 512)
(generate 89 "art-style" "ukiyo-e style cherry blossoms and mount fuji" "ukiyoe-fuji" 512 512)
(generate 90 "art-style" "persian miniature painting, garden scene with birds" "persian-miniature" 512 512)

;; --- 91-100: Hero/Banner images (1024px for README) ---
(generate 91 "hero" "wide landscape of rolling hills with a single tree, golden hour, cinematic" "hero-golden-tree" 1024 512)
(generate 92 "hero" "panoramic view of a futuristic city skyline at dusk" "hero-future-city" 1024 512)
(generate 93 "hero" "abstract flowing gradient, purple to blue to cyan, smooth waves" "hero-gradient-wave" 1024 512)
(generate 94 "hero" "open source community, diverse people collaborating around a table with laptops" "hero-community" 1024 512)
(generate 95 "hero" "library of babel, infinite bookshelves stretching into distance" "hero-babel-library" 1024 512)
(generate 96 "hero" "forge with molten metal and sparks, craftsmanship concept" "hero-forge" 1024 512)
(generate 97 "hero" "ocean waves at sunrise, long exposure photography" "hero-ocean-sunrise" 1024 512)
(generate 98 "hero" "starfield with nebula, wide format space panorama" "hero-starfield" 1024 512)
(generate 99 "hero" "zen stones stacked on beach at sunset, balance and harmony" "hero-zen-stones" 1024 512)
(generate 100 "hero" "ancient tree with massive roots, wisdom and knowledge concept, magical lighting" "hero-wisdom-tree" 1024 512)

;;; Summary
(close-port *log-port*)

(format #t "~%============================================================~%")
(format #t "Generation complete!~%")
(format #t "Total: ~a  Succeeded: ~a  Failed: ~a~%" *total* *succeeded* *failed*)
(format #t "Log: ~a~%" *log-path*)
(format #t "============================================================~%")

(exit (if (= *failed* 0) 0 1))
