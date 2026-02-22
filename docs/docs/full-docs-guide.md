# Full Documentation Guide

This section is the comprehensive reference for Jac. Whether you're learning the language from scratch, integrating AI into an app, or deploying to production, the pages below cover everything you need. Use this guide to find the right starting point for what you're trying to do.

---

## How This Section Is Organized

The Full Documentation is grouped into nine areas. Each area mixes **tutorials** (hands-on, step-by-step) with **references** (complete specification and API details) so you can learn and look things up in the same place.

| Section | What It Covers | Start Here If You Want To... |
|---------|---------------|-------------------------------|
| [Core Language](#core-language) | Syntax, types, functions, objects, Object-Spatial Programming, concurrency | Learn Jac from the ground up or look up language semantics |
| [AI Programming](#ai-programming) | `by llm()`, structured outputs, agentic patterns, multimodal AI | Add AI capabilities to your Jac code |
| [Full-Stack Development](#full-stack-development) | Codespaces, components, state, routing, authentication | Build a complete web app with frontend and backend in Jac |
| [Deployment](#deployment) | Local server, Kubernetes, jac-scale | Ship your app to production |
| [Tools & Config](#tools--config) | CLI commands, configuration files, testing, debugging | Set up your development environment or debug an issue |
| [Ecosystem](#ecosystem) | Python interop, library mode, plugin overview | Use Python libraries in Jac or embed Jac in a Python project |
| [Quick Reference](#quick-reference) | Appendices, walker responses, graph operations | Look up specific API patterns and cheat sheets |
| [Examples](#examples) | LittleX, EmailBuddy, RAG chatbot, RPG generator | See complete, working applications built in Jac |
| [Troubleshooting](#troubleshooting) | Common errors, FAQ, debugging tips | Fix a problem you've run into |

---

## Core Language

Start with **[Jac Basics](tutorials/language/basics.md)** for a gentle introduction to the syntax. The **[Foundation Reference](reference/language/foundation.md)** and **[Functions & Objects](reference/language/functions-objects.md)** pages are the definitive specification for types, control flow, classes, and more.

Jac's unique graph-based programming model is covered in the **[OSP Guide](tutorials/language/osp.md)** (tutorial) and **[OSP Reference](reference/language/osp.md)** (specification). If you need parallel execution, see **[Concurrency](reference/language/concurrency.md)**. Power users will find edge cases and niche features in **[Advanced Features](reference/language/advanced.md)**.

New to programming entirely? The **[Programming Primer](tutorials/language/coding_primer.md)** covers foundational concepts before diving into Jac.

## AI Programming

The **[Getting Started with AI](tutorials/ai/quickstart.md)** tutorial walks you through your first `by llm()` call. From there, **[Structured Outputs](tutorials/ai/structured-outputs.md)** shows how to get typed, validated responses from LLMs, and **[Agentic AI](tutorials/ai/agentic.md)** covers building multi-step AI workflows.

For image and audio processing, see **[Multimodal AI](tutorials/ai/multimodal.md)**. The **[AI Integration Reference](reference/language/ai-integration.md)** documents every AI-related construct, and **[byLLM Plugin](reference/plugins/byllm.md)** covers the plugin that powers it all.

## Full-Stack Development

Begin with **[Project Setup](tutorials/fullstack/setup.md)** to scaffold a full-stack Jac project. The tutorials then walk through **[Components](tutorials/fullstack/components.md)**, **[State Management](tutorials/fullstack/state.md)**, **[Backend Integration](tutorials/fullstack/backend.md)**, **[Authentication](tutorials/fullstack/auth.md)**, and **[Routing](tutorials/fullstack/routing.md)** in order.

The **[Full-Stack Reference](reference/language/full-stack.md)** is the complete specification for codespaces (`sv`, `cl`, `na`), and the **[jac-client Plugin](reference/plugins/jac-client.md)** documents the auto-generated client SDK.

## Deployment

**[Local API Server](tutorials/production/local.md)** shows how to run your app as a standalone API. When you're ready for scale, **[Kubernetes](tutorials/production/kubernetes.md)** covers container orchestration. The **[Deployment Reference](reference/language/deployment.md)** and **[jac-scale Plugin](reference/plugins/jac-scale.md)** document the full deployment pipeline.

## Tools & Config

The **[CLI Reference](reference/cli/index.md)** documents every `jac` subcommand. **[Configuration](reference/config/index.md)** covers project settings. For validating your code, see **[Testing](reference/testing.md)**, and for tracking down bugs, see **[Debugging](tutorials/language/debugging.md)**.

## Ecosystem

**[Overview](reference/language/ecosystem.md)** describes the Jac plugin ecosystem. **[Python Integration](reference/language/python-integration.md)** explains how to import and use Python packages in Jac, and **[Library Mode](reference/language/library-mode.md)** shows how to use Jac modules from Python.

## Quick Reference

Lookup tables and concise summaries: **[Appendices](reference/language/appendices.md)** for grammar and operator precedence, **[Walker Responses](reference/language/walker-responses.md)** for the walker return protocol, and **[Graph Operations](reference/language/graph-operations.md)** for edge and node manipulation patterns.

## Examples

Complete applications you can clone and run: **[LittleX](tutorials/examples/littlex.md)** (a Twitter clone), **[EmailBuddy](tutorials/examples/emailbuddy.md)** (an AI email assistant), **[RAG Chatbot](tutorials/examples/rag-chatbot.md)**, and **[RPG Level Generator](tutorials/examples/rpg.md)**. The **[Examples Overview](tutorials/examples/index.md)** page lists them all.

## Troubleshooting

Hit a wall? **[Troubleshooting](tutorials/troubleshooting.md)** covers common errors, environment issues, and debugging strategies.
