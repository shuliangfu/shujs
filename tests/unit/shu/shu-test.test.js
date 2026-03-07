// shu test：覆盖 describe/it/test、钩子、assert、expect、mock、snapshot、t、Deno/Bun 兼容，加载后自动执行。
const { describe, it, test, assert, expect, mock, snapshot } = require('shu:test')

// 临时：仅跑此用例验证 assert 失败是否计入 failed（跑完可删或改回）
// describe.only('__assert_fail_check', () => {
//   it.only('assert.strictEqual(1,2) should fail', () => {
//     assert.strictEqual(1, 2)
//   })
// })

// ---------------------------------------------------------------------------
// assert（Node 风格）：每个断言方法均覆盖「通过」与「不通过」两类用例
// ---------------------------------------------------------------------------
describe('assert', () => {
  // --- assert.ok ---
  describe('ok', () => {
    it('passes for truthy: true, 1, non-empty string, object, array', () => {
      assert.ok(true)
      assert.ok(1)
      assert.ok('x')
      assert.ok({})
      assert.ok([])
    })
    it('fails (throws) for 0', () => {
      assert.throws(() => assert.ok(0))
    })
    it('fails (throws) for false', () => {
      assert.throws(() => assert.ok(false))
    })
    it('fails (throws) for null', () => {
      assert.throws(() => assert.ok(null))
    })
    it('fails (throws) for undefined', () => {
      assert.throws(() => assert.ok(undefined))
    })
    it('fails (throws) for empty string', () => {
      assert.throws(() => assert.ok(''))
    })
  })

  // --- assert.strictEqual ---
  describe('strictEqual', () => {
    it('passes when actual === expected (primitives)', () => {
      assert.strictEqual(1, 1)
      assert.strictEqual('a', 'a')
      assert.strictEqual(true, true)
      assert.strictEqual(null, null)
      assert.strictEqual(undefined, undefined)
    })
    it('passes when same object reference', () => {
      const o = {}
      assert.strictEqual(o, o)
    })
    it('fails (throws) when numbers differ', () => {
      assert.throws(() => assert.strictEqual(1, 2))
    })
    it('fails (throws) when strings differ', () => {
      assert.throws(() => assert.strictEqual('a', 'b'))
    })
    it('fails (throws) when different object refs same content', () => {
      assert.throws(() => assert.strictEqual({ a: 1 }, { a: 1 }))
    })
    it('fails (throws) when type differs', () => {
      assert.throws(() => assert.strictEqual(1, '1'))
    })
  })

  // --- assert.deepStrictEqual ---
  describe('deepStrictEqual', () => {
    it('passes for equal plain objects', () => {
      assert.deepStrictEqual({ a: 1 }, { a: 1 })
    })
    it('passes for equal arrays', () => {
      assert.deepStrictEqual([1, 2], [1, 2])
    })
    it('passes for nested structures', () => {
      assert.deepStrictEqual({ a: { b: 2 } }, { a: { b: 2 } })
    })
    it('fails (throws) when values differ', () => {
      assert.throws(() => assert.deepStrictEqual({ a: 1 }, { a: 2 }))
    })
    it('fails (throws) when keys differ', () => {
      assert.throws(() => assert.deepStrictEqual({ a: 1 }, { b: 1 }))
    })
    it('fails (throws) when array length or elements differ', () => {
      assert.throws(() => assert.deepStrictEqual([1, 2], [1, 2, 3]))
      assert.throws(() => assert.deepStrictEqual([1, 2], [1, 3]))
    })
  })

  // --- assert.throws ---
  describe('throws', () => {
    it('passes when fn throws', () => {
      assert.throws(() => {
        throw new Error('expected')
      })
    })
    it('passes when fn throws any error', () => {
      assert.throws(() => {
        throw new TypeError('t')
      })
    })
    it('fails (throws) when fn does not throw', () => {
      assert.throws(() => assert.throws(() => {}))
    })
    it('fails (throws) when fn returns normally', () => {
      assert.throws(() => assert.throws(() => 42))
    })
  })

  // --- assert.doesNotThrow ---
  describe('doesNotThrow', () => {
    it('passes when fn does not throw', () => {
      assert.doesNotThrow(() => {})
    })
    it('passes when fn returns a value', () => {
      assert.doesNotThrow(() => 1)
    })
    it('fails (throws) when fn throws', () => {
      assert.throws(() =>
        assert.doesNotThrow(() => {
          throw new Error('x')
        })
      )
    })
  })

  // --- assert.fail ---
  describe('fail', () => {
    it('always throws (no-arg)', () => {
      assert.throws(() => assert.fail())
    })
    it('always throws (with message)', () => {
      assert.throws(() => assert.fail('must throw'))
    })
  })

  // --- assert.rejects ---
  describe('rejects', () => {
    it('passes: returns promise that resolves to error when promise rejects', async () => {
      const err = new Error('rejected')
      const p = assert.rejects(Promise.reject(err))
      const got = await p
      assert.strictEqual(got, err)
    })
    it('passes: accepts async function that rejects', async () => {
      const err = new Error('async-rej')
      const p = assert.rejects(async () => {
        throw err
      })
      const got = await p
      assert.strictEqual(got, err)
    })
    it('fails (returns rejecting promise) when promise resolves', async () => {
      await assert.rejects(assert.rejects(Promise.resolve(1)))
    })
    it('fails (returns rejecting promise) when async fn resolves', async () => {
      await assert.rejects(assert.rejects(async () => 1))
    })
  })

  // --- assert.doesNotReject ---
  describe('doesNotReject', () => {
    it('passes: returns promise that resolves to value when promise resolves', async () => {
      const value = { ok: true }
      const p = assert.doesNotReject(Promise.resolve(value))
      const got = await p
      assert.strictEqual(got, value)
    })
    it('passes: accepts async function that resolves', async () => {
      const value = 42
      const p = assert.doesNotReject(async () => value)
      const got = await p
      assert.strictEqual(got, value)
    })
    it('fails (returns rejecting promise) when promise rejects', async () => {
      const err = new Error('rej')
      await assert.rejects(() => assert.doesNotReject(Promise.reject(err)))
    })
    it('fails (returns rejecting promise) when async fn throws', async () => {
      await assert.rejects(() =>
        assert.doesNotReject(async () => {
          throw new Error('async throw')
        })
      )
    })
  })

  // --- Deno 别名：与对应方法行为一致，通过与不通过均验证 ---
  describe('Deno aliases', () => {
    it('assertEquals passes for equal values, fails for unequal', () => {
      assert.assertEquals(1, 1)
      assert.assertEquals({ a: 1 }, { a: 1 })
      assert.throws(() => assert.assertEquals(1, 2))
      assert.throws(() => assert.assertEquals({ a: 1 }, { a: 2 }))
    })
    it('assertStrictEquals passes for strict equal, fails otherwise', () => {
      assert.assertStrictEquals(1, 1)
      const o = {}
      assert.assertStrictEquals(o, o)
      assert.throws(() => assert.assertStrictEquals(1, 2))
    })
    it('assertThrows passes when fn throws, fails when fn does not throw', () => {
      assert.assertThrows(() => {
        throw new Error('e')
      })
      assert.throws(() => assert.assertThrows(() => {}))
    })
    it('assertRejects passes when promise rejects, fails when promise resolves', async () => {
      const err = new Error('rej-alias')
      const got = await assert.assertRejects(Promise.reject(err))
      assert.strictEqual(got, err)
      await assert.rejects(() => assert.assertRejects(Promise.resolve(1)))
    })
  })
})

// ---------------------------------------------------------------------------
// test context (t.name / t.done / t.skip / t.step)
// ---------------------------------------------------------------------------
describe('test context', () => {
  it('t.name is current test name', t => {
    assert.strictEqual(t.name, 't.name is current test name')
  })

  it('it(..., { timeout }) accepts option', { timeout: 5000 }, () => {
    assert.ok(true)
  })

  it('t.done() marks test done', t => {
    t.done()
  })

  it('t.skip() skips rest', t => {
    t.skip()
  })

  it('t.todo() marks test todo', t => {
    t.todo()
  })

  it('t.step runs sub-steps (Deno)', async t => {
    await t.step('step1', () => {
      assert.strictEqual(1, 1)
    })
    await t.step('step2', async () => {
      await Promise.resolve()
      assert.ok(true)
    })
  })
})

// ---------------------------------------------------------------------------
// snapshot
// ---------------------------------------------------------------------------
describe('snapshot', () => {
  it('snapshot(name, value) records and compares', () => {
    snapshot('example-snap', { x: 1 })
    snapshot('example-snap', { x: 1 })
  })

  it('snapshot(name, value) throws on mismatch', () => {
    snapshot('bound-snap-mismatch', { v: 1 })
    assert.throws(() => snapshot('bound-snap-mismatch', { v: 2 }))
  })
})

// ---------------------------------------------------------------------------
// Deno 兼容别名与 it.ignore
// ---------------------------------------------------------------------------
describe('Deno compat', () => {
  it('assertEquals / assertStrictEquals / assertThrows', () => {
    assert.assertEquals(1, 1)
    assert.assertStrictEquals('a', 'a')
    assert.assertThrows(() => {
      throw new Error('expected')
    })
  })

  it.ignore('it.ignore skips this test', () => {
    assert.fail('should not run')
  })
})

// ---------------------------------------------------------------------------
// it/test options（第三参 options 对象）：skip / todo / timeout / skipIf
// ---------------------------------------------------------------------------
describe('it/test options object', () => {
  it(
    'it(name, fn, { skip: true }) skips test',
    () => {
      assert.fail('should be skipped')
    },
    { skip: true }
  )

  it(
    'it(name, fn, { todo: true }) marks as todo',
    () => {
      assert.ok(true)
    },
    { todo: true }
  )

  it(
    'it(name, fn, { timeout: N }) accepts timeout in options',
    () => {
      assert.ok(true)
    },
    { timeout: 1000 }
  )

  it(
    'it(name, fn, { skipIf: true }) skips test',
    () => {
      assert.fail('should be skipped')
    },
    { skipIf: true }
  )

  it(
    'it(name, fn, { skipIf: false }) runs test',
    () => {
      assert.ok(true)
    },
    { skipIf: false }
  )

  it(
    'it(name, fn, { skipIf: fn }) skips when fn returns true',
    () => {
      assert.fail('should be skipped')
    },
    { skipIf: () => true }
  )

  it(
    'it(name, fn, { skipIf: fn }) runs when fn returns false',
    () => {
      assert.ok(true)
    },
    { skipIf: () => false }
  )

  it(
    'test(name, fn, { skip: true }) skips',
    () => {
      assert.fail('should be skipped')
    },
    { skip: true }
  )

  it(
    'options can be empty object',
    () => {
      assert.ok(true)
    },
    {}
  )
})

// ---------------------------------------------------------------------------
// options 继承：describe 的 timeout/skipIf 被子 suite 与 it 继承，it 级覆盖
// ---------------------------------------------------------------------------
describe('options inheritance', () => {
  describe(
    'suite with timeout',
    () => {
      it('it without options inherits suite timeout', () => {
        assert.ok(true)
      })
    },
    { timeout: 2000 }
  )

  describe(
    'suite with skipIf: true',
    () => {
      it('it without options inherits skipIf and is skipped', () => {
        assert.fail('should be skipped')
      })
    },
    { skipIf: true }
  )

  describe(
    'outer with timeout',
    () => {
      describe('inner without options', () => {
        it('inner it inherits outer timeout', () => {
          assert.ok(true)
        })
      })
    },
    { timeout: 3000 }
  )

  describe(
    'suite timeout overridden by it',
    () => {
      it(
        'it overrides with own timeout',
        () => {
          assert.ok(true)
        },
        { timeout: 500 }
      )
    },
    { timeout: 10000 }
  )
})

// ---------------------------------------------------------------------------
// describe.skip / describe.ignore / describe.only
// ---------------------------------------------------------------------------
describe('describe modifiers', () => {
  describe.skip('describe.skip skips whole suite', () => {
    it('should not run', () => {
      assert.fail('suite skipped')
    })
  })

  describe.ignore('describe.ignore skips whole suite', () => {
    it('should not run', () => {
      assert.fail('suite ignored')
    })
  })

  it('describe.only / it.only exist and are callable', () => {
    assert.strictEqual(typeof describe.only, 'function')
    assert.strictEqual(typeof it.only, 'function')
  })
})

// ---------------------------------------------------------------------------
// beforeAll / afterAll / beforeEach / afterEach
// ---------------------------------------------------------------------------
describe('hooks', () => {
  const order = []
  beforeAll(() => {
    order.push('beforeAll')
  })
  afterAll(() => {
    order.push('afterAll')
    assert.ok(order.indexOf('beforeAll') >= 0)
    assert.ok(order.indexOf('beforeEach') >= 0)
    assert.ok(order.indexOf('afterEach') >= 0)
  })
  beforeEach(() => {
    order.push('beforeEach')
  })
  afterEach(() => {
    order.push('afterEach')
  })

  it('first test sees hooks', () => {
    assert.strictEqual(order.length, 2) // beforeAll, beforeEach
    assert.strictEqual(order[0], 'beforeAll')
    assert.strictEqual(order[1], 'beforeEach')
  })

  it('second test sees beforeEach/afterEach order', () => {
    assert.ok(order.indexOf('afterEach') >= 0)
    assert.ok(order.indexOf('beforeEach') >= 0)
  })
})

// ---------------------------------------------------------------------------
// it.skip / it.todo / test.skipIf / test.serial
// ---------------------------------------------------------------------------
describe('it and test modifiers', () => {
  it.skip('it.skip skips this test', () => {
    assert.fail('should not run')
  })

  it.todo('it.todo marks test as todo')

  test.skipIf(true)('test.skipIf(true) skips this test', () => {
    assert.fail('should not run')
  })

  test.skipIf(false)('test.skipIf(false) runs this test', () => {
    assert.ok(true)
  })

  test.serial('test.serial runs like test', () => {
    assert.strictEqual(1, 1)
  })
})

// ---------------------------------------------------------------------------
// mock.method
// ---------------------------------------------------------------------------
describe('mock.method', () => {
  it('wraps object method and records calls', () => {
    const obj = { add: (a, b) => a + b }
    const mockAdd = mock.method(obj, 'add')
    assert.strictEqual(obj.add(2, 3), 5)
    assert.strictEqual(mockAdd.callCount, 1)
    assert.deepStrictEqual(mockAdd.calls[0], [2, 3])
  })
})

// ---------------------------------------------------------------------------
// expect (Bun/Jest 风格)
// ---------------------------------------------------------------------------
describe('expect', () => {
  it('toBe / toEqual / toBeTruthy / toBeFalsy', () => {
    expect(1).toBe(1)
    expect({ a: 1 }).toEqual({ a: 1 })
    expect(true).toBeTruthy()
    expect(false).toBeFalsy()
  })

  it('toThrow on function', () => {
    expect(() => {
      throw new Error('expected')
    }).toThrow()
  })

  it('toReject on promise', async () => {
    await expect(Promise.reject(new Error('rej'))).toReject()
  })
})

// ---------------------------------------------------------------------------
// expect 边界：期望失败时必须抛错
// ---------------------------------------------------------------------------
describe('expect boundary', () => {
  it('expect(1).toBe(2) throws', () => {
    assert.throws(() => expect(1).toBe(2))
  })

  it('expect(() => {}).toThrow() throws', () => {
    assert.throws(() => expect(() => {}).toThrow())
  })

  it('expect(false).toBeTruthy() throws', () => {
    assert.throws(() => expect(false).toBeTruthy())
  })

  it('expect(true).toBeFalsy() throws', () => {
    assert.throws(() => expect(true).toBeFalsy())
  })
})

// ---------------------------------------------------------------------------
// test.each
// ---------------------------------------------------------------------------
describe('test.each', () => {
  test.each([
    [1, 2, 3],
    [2, 3, 5]
  ])(
    row => `adds ${row[0]}+${row[1]}=${row[2]}`,
    (t, a, b, expected) => {
      assert.strictEqual(a + b, expected)
    }
  )
})

// ---------------------------------------------------------------------------
// mock.fn()
// ---------------------------------------------------------------------------
describe('mock.fn', () => {
  it('records callCount and calls without impl', () => {
    const fn = mock.fn()
    assert.strictEqual(fn.callCount, 0)
    assert.strictEqual(fn.calls.length, 0)

    fn()
    assert.strictEqual(fn.callCount, 1)
    assert.strictEqual(fn.calls.length, 1)
    assert.strictEqual(fn.calls[0].length, 0)

    fn(1, 'a')
    assert.strictEqual(fn.callCount, 2)
    assert.strictEqual(fn.calls[0].length, 0)
    assert.strictEqual(fn.calls[1].length, 2)
    assert.strictEqual(fn.calls[1][0], 1)
    assert.strictEqual(fn.calls[1][1], 'a')
  })

  it('with impl records and returns result', () => {
    const fn = mock.fn((a, b) => a + b)
    const r = fn(2, 3)
    assert.strictEqual(r, 5)
    assert.strictEqual(fn.callCount, 1)
    assert.strictEqual(fn.calls[0][0], 2)
    assert.strictEqual(fn.calls[0][1], 3)
  })

  it('injected as callback records after call', () => {
    const onDone = mock.fn()
    function doSomething(cb) {
      cb('ok')
    }
    doSomething(onDone)
    assert.strictEqual(onDone.callCount, 1)
    assert.strictEqual(onDone.calls[0][0], 'ok')
  })
})

// ---------------------------------------------------------------------------
// 故意失败用例：用于验证 runner 是否能正确统计「断言失败」
// 注意：本区块中的测试都会失败，仅用于验证失败路径与统计行为。
// ---------------------------------------------------------------------------
describe('intentional assertion failures', () => {
  it('assert.ok should fail intentionally', () => {
    assert.ok(false)
  })

  it('assert.strictEqual should fail intentionally', () => {
    assert.strictEqual(1, 2)
  })

  it('assert.deepStrictEqual should fail intentionally', () => {
    assert.deepStrictEqual({ a: 1 }, { a: 2 })
  })

  it('assert.throws should fail intentionally', () => {
    assert.throws(() => {})
  })

  it('assert.doesNotThrow should fail intentionally', () => {
    assert.doesNotThrow(() => {
      throw new Error('intentional throw')
    })
  })

  it('assert.fail should fail intentionally', () => {
    assert.fail('intentional fail')
  })

  it('assert.rejects should fail intentionally', async () => {
    await assert.rejects(Promise.resolve(1))
  })

  it('assert.doesNotReject should fail intentionally', async () => {
    await assert.doesNotReject(Promise.reject(new Error('intentional reject')))
  })

  it('assert.assertEquals should fail intentionally', () => {
    assert.assertEquals(1, 2)
  })

  it('assert.assertStrictEquals should fail intentionally', () => {
    assert.assertStrictEquals(1, 2)
  })

  it('assert.assertThrows should fail intentionally', () => {
    assert.assertThrows(() => {})
  })

  it('assert.assertRejects should fail intentionally', async () => {
    await assert.assertRejects(Promise.resolve(1))
  })

  it('expect.toBe should fail intentionally', () => {
    expect(1).toBe(2)
  })

  it('expect.toEqual should fail intentionally', () => {
    expect({ a: 1 }).toEqual({ a: 2 })
  })

  it('expect.toBeTruthy should fail intentionally', () => {
    expect(false).toBeTruthy()
  })

  it('expect.toBeFalsy should fail intentionally', () => {
    expect(true).toBeFalsy()
  })

  it('expect.toThrow should fail intentionally', () => {
    expect(() => {}).toThrow()
  })

  it('expect.toReject should fail intentionally', async () => {
    await expect(Promise.resolve(1)).toReject()
  })
})
