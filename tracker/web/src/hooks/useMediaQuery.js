import { useEffect, useState } from "react";

/** @param {string} query */
export function useMediaQuery(query) {
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || !window.matchMedia) return false;
    return window.matchMedia(query).matches;
  });

  useEffect(() => {
    const mq = window.matchMedia(query);
    const onChange = (e) => setMatches(e.matches);
    setMatches(mq.matches);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, [query]);

  return matches;
}

/** 窄屏或触摸设备 → 使用手机布局（纵向看板） */
export function useMobileLayout() {
  const narrow = useMediaQuery("(max-width: 768px)");
  const touch = useMediaQuery("(hover: none) and (pointer: coarse)");
  return narrow || touch;
}
