/**
 * PigeonBoxError —— SDK 统一错误形态（业务 envelope / HTTP 错误）。
 *
 * errcode 数值与 contracts/errcode 一致（gen-ts 不导出常量，此处镜像一份；
 * 契约加码时同步更新并以 contracts 为真相源）。
 */
export class PigeonBoxError extends Error {
  /** errcode 统一业务码（0 = 服务端未给出，见 message） */
  readonly code: number;
  /** HTTP 状态码（传输层失败时为 0） */
  readonly httpStatus: number;

  constructor(message: string, code = 0, httpStatus = 0) {
    super(message);
    this.name = "PigeonBoxError";
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

/** errcode 统一业务码镜像（真相源：contracts/errcode） */
export const ErrCode = {
  InvalidParam: 10001,
  Unauthorized: 10002,
  Forbidden: 10003,
  NotFound: 10004,
  RateLimit: 10005,
  Unavailable: 10006,
  Timeout: 10007,
  Internal: 10008,
  TooLarge: 10010,
  AnonymousQuota: 10014,

  ShareNotFound: 20001,
  ShareExpired: 20002,
  PasswordWrong: 20003,
  ReachLimit: 20004,
  PickupCodeNotFound: 20005,
  PickupCodeExhausted: 20007,
  ShareBlocked: 20012,
} as const;

/** 判定错误链是否命中指定 errcode（非 PigeonBoxError 一律 false）。 */
export function isErrCode(err: unknown, code: number): boolean {
  return err instanceof PigeonBoxError && err.code === code;
}

/** 10004 资源不存在 / 20001 分享不存在 / 20005 取件码不存在 —— 「查无此物」族。 */
export function isNotFound(err: unknown): boolean {
  return (
    isErrCode(err, ErrCode.NotFound) ||
    isErrCode(err, ErrCode.ShareNotFound) ||
    isErrCode(err, ErrCode.PickupCodeNotFound)
  );
}
