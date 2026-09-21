## Text styling
Normal **bold** *italic* ***both*** ~~removed~~ and `inline code`.
Inline formula: $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$.
A hard break here.  
Next line.

## Lists
- Item 1
- Item 2
  - Nested item
    - Deep item
- Item 3

1. First step
2. Second step
   1. Sub-step A
   2. Sub-step B
3. Third step

- [x] Completed task
- [ ] Pending task

## Quotes
> Outer quote
>
> > Nested quote
> >
> > > Deep quote

## Tables
| Left aligned | Center aligned | Right aligned |
| :--- | :---: | ---: |
| Alpha | Active | 1,250 |
| A longer value that wraps on narrow screens | Pending | 340 |

## Code
```python
def fibonacci(n: int) -> list[int]:
    # Keep the original indentation.
    sequence = [0, 1]
    return sequence[:n]
```

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "Build complete."
```

```json
{"project": "Markdown", "version": 1, "active": true}
```

## Mathematics
$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

---
The divider fills the text column.
