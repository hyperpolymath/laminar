;; SPDX-License-Identifier: AGPL-3.0-or-later
;; SPDX-FileCopyrightText: 2025 Jonathan D.A. Jewell
;; ECOSYSTEM.scm — laminar

(ecosystem
  (version "1.0.0")
  (name "laminar")
  (type "project")
  (purpose "// SPDX-License-Identifier: Apache-2.0")

  (position-in-ecosystem
    "Part of hyperpolymath ecosystem. Follows RSR guidelines.")

  (related-projects
    (project (name "rhodium-standard-repositories")
             (url "https://github.com/hyperpolymath/rhodium-standard-repositories")
             (relationship "standard")))

  (what-this-is "// SPDX-License-Identifier: Apache-2.0")
  (what-this-is-not "- NOT exempt from RSR compliance"))
