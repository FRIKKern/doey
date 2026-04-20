# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## 2026-04-20 — Discord notifications

- feat(discord): Boss events (stop-notify, on-notification) now forward to Discord when bound; body via stdin, argv-safe; privacy default `metadata_only`; 200-byte rune-bound truncation + 12-pattern redaction; opt-in e2e + argv-leak tests; see `docs/discord.md`.
